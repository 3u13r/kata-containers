#!/usr/bin/env bash

# Copyright (c) 2024 Red Hat
#
# SPDX-License-Identifier: Apache-2.0
#
# Provides a library to deal with the CoCo KBS
#

set -o errexit
set -o nounset
set -o pipefail

kubernetes_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=1091
source "${kubernetes_dir}/../../gha-run-k8s-common.sh"

# Where the kbs sources will be cloned
readonly COCO_KBS_DIR="/tmp/kbs"
# The k8s namespace where the kbs service is deployed
readonly KBS_NS="coco-tenant"
# The kbs service name
readonly KBS_SVC_NAME="kbs"

# Delete the kbs on Kubernetes
#
# Note: assume the kbs sources were cloned to $COCO_KBS_DIR
#
function kbs_k8s_delete() {
	pushd "$COCO_KBS_DIR"
	kubectl delete -k kbs/config/kubernetes/overlays
	popd
}

# Deploy the kbs on Kubernetes
#
# Parameters:
#	$1 - apply the specificed ingress handler to expose the service externally
#
function kbs_k8s_deploy() {
	local image
	local image_tag
	local ingress=${1:-}
	local repo
	local svc_host
	local timeout
	local kbs_ip
	local kbs_port
	local version

	# yq is needed by get_from_kata_deps
	ensure_yq

	# Read from versions.yaml
	repo=$(get_from_kata_deps "externals.coco-kbs.url")
	version=$(get_from_kata_deps "externals.coco-kbs.version")
	image=$(get_from_kata_deps "externals.coco-kbs.image")
	image_tag=$(get_from_kata_deps "externals.coco-kbs.image_tag")

	# The ingress handler for AKS relies on the cluster's name which in turn
	# contain the HEAD commit of the kata-containers repository (supposedly the
	# current directory). It will be needed to save the cluster's name before
	# it switches to the kbs repository and get a wrong HEAD commit.
	if [ -z "${AKS_NAME:-}" ]; then
		AKS_NAME=$(_print_cluster_name)
		export AKS_NAME
	fi

	if [ -d "$COCO_KBS_DIR" ]; then
		rm -rf "$COCO_KBS_DIR"
	fi

	echo "::group::Clone the kbs sources"
	git clone --depth 1 "${repo}" "$COCO_KBS_DIR"
	pushd "$COCO_KBS_DIR"
	git fetch --depth=1 origin "${version}"
	git checkout FETCH_HEAD -b kbs_$$
	echo "::endgroup::"

	pushd kbs/config/kubernetes/

	# Tests should fill kbs resources later, however, the deployment
	# expects at least one secret served at install time.
	echo "somesecret" > overlays/key.bin

	echo "::group::Update the kbs container image"
	install_kustomize
	pushd base
	kustomize edit set image "kbs-container-image=${image}:${image_tag}"
	popd
	echo "::endgroup::"

	[ -n "$ingress" ] && _handle_ingress "$ingress"

	echo "::group::Deploy the KBS"
	./deploy-kbs.sh
	popd
	popd

	if ! waitForProcess "120" "10" "kubectl -n \"$KBS_NS\" get pods | \
		grep -q '^kbs-.*Running.*'"; then
		echo "ERROR: KBS service pod isn't running"
		echo "::group::DEBUG - describe kbs deployments"
		kubectl -n "$KBS_NS" get deployments || true
		echo "::endgroup::"
		echo "::group::DEBUG - describe kbs pod"
		kubectl -n "$KBS_NS" describe pod -l app=kbs || true
		echo "::endgroup::"
		return 1
	fi
	echo "::endgroup::"

	# By default, the KBS service is reachable within the cluster only,
	# thus the following healthy checker should run from a pod. So start a
	# debug pod where it will try to get a response from the service. The
	# expected response is '404 Not Found' because it will request an endpoint
	# that does not exist.
	#
	echo "::group::Check the service healthy"
	kbs_ip=$(kubectl get -o jsonpath='{.spec.clusterIP}' svc "$KBS_SVC_NAME" -n "$KBS_NS" 2>/dev/null)
	kbs_port=$(kubectl get -o jsonpath='{.spec.ports[0].port}' svc "$KBS_SVC_NAME" -n "$KBS_NS" 2>/dev/null)
	local pod=kbs-checker-$$
	kubectl run "$pod" --image=quay.io/prometheus/busybox --restart=Never -- \
		sh -c "wget -O- --timeout=5 \"${kbs_ip}:${kbs_port}\" || true"
	if ! waitForProcess "60" "10" "kubectl logs \"$pod\" 2>/dev/null | grep -q \"404 Not Found\""; then
		echo "ERROR: KBS service is not responding to requests"
		echo "::group::DEBUG - kbs logs"
		kubectl -n "$KBS_NS" logs -l app=kbs || true
		echo "::endgroup::"
		kubectl delete pod "$pod"
		return 1
	fi
	kubectl delete pod "$pod"
	echo "KBS service respond to requests"
	echo "::endgroup::"

	if [ -n "$ingress" ]; then
		echo "::group::Check the kbs service is exposed"
		svc_host=$(kbs_k8s_svc_host)
		if [ -z "$svc_host" ]; then
			echo "ERROR: service host not found"
			return 1
		fi

		# AZ DNS can take several minutes to update its records so that
		# the host name will take a while to start resolving.
		timeout=350
		echo "Trying to connect at $svc_host. Timeout=$timeout"
		if ! waitForProcess "$timeout" "30" "curl -s -I \"$svc_host\" | grep -q \"404 Not Found\""; then
			echo "ERROR: service seems to not respond on $svc_host host"
			curl -I "$svc_host"
			return 1
		fi
		echo "KBS service respond to requests at $svc_host"
		echo "::endgroup::"
	fi
}

# Return the kbs service host name in case ingress is configured
# otherwise the cluster IP.
#
kbs_k8s_svc_host() {
	if kubectl get ingress -n "$KBS_NS" | grep -q kbs; then
		kubectl get ingress kbs -n "$KBS_NS" \
			-o jsonpath='{.spec.rules[0].host}' 2>/dev/null
	else
		kubectl get svc kbs -n "$KBS_NS" \
			-o jsonpath='{.spec.clusterIP}' 2>/dev/null
	fi
}

# Choose the appropriated ingress handler.
#
# To add a new handler, create a function named as _handle_ingress_NAME where
# NAME is the handler name. This is enough for this method to pick up the right
# implementation.
#
_handle_ingress() {
	local ingress="$1"

	type -a "_handle_ingress_$ingress" &>/dev/null || {
		echo "ERROR: ingress '$ingress' handler not implemented";
		return 1;
	}

	"_handle_ingress_$ingress"
}

# Implement the ingress handler for AKS.
#
_handle_ingress_aks() {
	local dns_zone

	dns_zone=$(get_cluster_specific_dns_zone "")

	# In case the DNS zone name is empty, the cluster might not have the HTTP
	# application routing add-on. Let's try to enable it.
	if [ -z "$dns_zone" ]; then
		echo "::group::Enable HTTP application routing add-on"
		enable_cluster_http_application_routing ""
		echo "::endgroup::"
		dns_zone=$(get_cluster_specific_dns_zone "")
	fi

	if [ -z "$dns_zone" ]; then
		echo "ERROR: the DNS zone name is nil, it cannot configure Ingress"
		return 1
	fi

	pushd "$COCO_KBS_DIR/kbs/config/kubernetes/overlays"

	echo "::group::$(pwd)/ingress.yaml"
	KBS_INGRESS_CLASS="addon-http-application-routing" \
		KBS_INGRESS_HOST="kbs.${dns_zone}" \
		envsubst < ingress.yaml | tee ingress.yaml.tmp
	echo "::endgroup::"
	mv ingress.yaml.tmp ingress.yaml

	kustomize edit add resource ingress.yaml
	popd
}