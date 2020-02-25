#!/usr/bin/env bash
#
# Copyright 2020 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# TODO(listx): CONVERT THIS TO TERRAFORM!

# Wire up the AUDITOR_SERVICE_NAME to receive events from GCR. This script only
# needs to be run 1x after the first deployment of the auditor, as long as
# AUDITOR_SERVACE_NAME doesn't change. Also, the "ensure-prod-storage.sh" script
# must run before this script, because that script creates both the
# AUDITOR_INVOKER_SVCACCT (used by this script) and the AUDITOR_SVCACCT (used by
# cip-auditor/deploy.sh).
#
# So the sequence should be:
#
# - Run ensure-prod-storage.sh
# - Run deploy.sh
# - Run this script.
#
# Thereafter, new deployments of the auditor only requires running the deploy.sh
# script.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
. "${SCRIPT_DIR}/lib.sh"

SUBSCRIPTION_NAME="cip-auditor-invoker"

# Get the auditor service's Cloud Run push endpoint (the HTTPS endpoint that the
# Pub/Sub subscription listening to the "gcr" topic can hit).
#
#   $1: GCP project ID
function get_push_endpoint() {
    if [ $# -lt 1 -o -z "$1" ]; then
        echo "get_push_endpoint(project_id) requires 1 argument" >&2
        return 1
    fi
    project_id="$1"

    gcloud \
        run services describe \
        "${AUDITOR_SERVICE_NAME}" \
        --platform=managed \
        --format='value(status.url)' \
        --project="${project_id}" \
        --region=us-central1
}

# This enables the necessary services to use Cloud Run.
#
#   $1: GCP project ID
function enable_services() {
    if [ $# -ne 1 -o -z "$1" ]; then
        echo "enable_services(project_id) requires 1 argument" >&2
        return 1
    fi
    project_id="$1"

    # Enable APIs.
    services=(
        "serviceusage.googleapis.com"
        "cloudresourcemanager.googleapis.com"
        "stackdriver.googleapis.com"
        "clouderrorreporting.googleapis.com"
        "run.googleapis.com"
    )
    echo "Enabling services"
    for service in "${services[@]}"; do
        gcloud --project="${project_id}" services enable "${service}"
    done
}

# This sets up the GCP project so that it can be ready to deploy the cip-auditor
# service onto Cloud Run.
#
#   $1: GCP project ID
#   $2: GCP project number
function link_run_to_pubsub() {
    if [ $# -lt 2 -o -z "$1" -o -z "$2" ]; then
        echo "link_run_to_pubsub(project_id, project_number) requires 2 arguments" >&2
        return 1
    fi
    project_id="$1"
    project_number="$2"

    # Create "gcr" topic if it doesn't exist yet.
    if ! gcloud pubsub topics list --format='value(name)' --project="${project_id}" \
        | grep "projects/${project_id}/topics/gcr"; then

        gcloud pubsub topics create gcr --project="${project_id}"
    fi

    # Allow the Pub/Sub to create auth tokens in the project. This is part of
    # the authentication bridge between the "gcr" Pub/Sub topic and the
    # "--no-allow-unauthenticated" Cloud Run service option.
    gcloud \
        projects add-iam-policy-binding \
        "${project_id}" \
        --member="serviceAccount:service-${project_number}@gcp-sa-pubsub.iam.gserviceaccount.com" \
        --role=roles/iam.serviceAccountTokenCreator

    # Create subscription if it doesn't exist yet.
    if ! gcloud pubsub subscriptions list --format='value(name)' --project="${project_id}" \
        | grep "projects/${project_id}/subscriptions/${SUBSCRIPTION_NAME}"; then

        # Find HTTPS push endpoint (invocation endpoint) of the auditor. This
        # URL will never change (part of the service name is baked into it), as
        # per https://cloud.google.com/run/docs/deploying#url.
        local auditor_endpoint
        auditor_endpoint=$(get_push_endpoint "${project_id}")

        gcloud \
            pubsub subscriptions create \
            "${SUBSCRIPTION_NAME}" \
            --topic=gcr \
            --expiration-period=never \
            --push-auth-service-account="$(svc_acct_email "${project_id}" "${AUDITOR_INVOKER_SVCACCT}")" \
            --push-endpoint="${auditor_endpoint}" \
            --project="${project_id}"
    fi
}

function main() {
    # We want to run in the artifacts project to get pubsub most easily.
    PROJECT_ID="k8s-artifacts-prod"
    PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format "value(projectNumber)")

    enable_services "${PROJECT_ID}"

    if ! get_push_endpoint "${PROJECT_ID}"; then
        echo >&2 "Could not determine push endpoint for the auditor's Cloud Run service."
        echo >&2 "Please run the cip-auditor/deploy.sh script to first deploy the auditor"
        echo >&2 "before re-running this script."
        exit 1
    fi

    link_run_to_pubsub "${PROJECT_ID}" "${PROJECT_NUMBER}"
}

main "$@"
