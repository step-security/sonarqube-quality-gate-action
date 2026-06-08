#!/usr/bin/env bash

source "$(dirname "$0")/common.sh"

if [[ -z "${SONAR_TOKEN}" ]]; then
  echo "Set the SONAR_TOKEN env variable."
  exit 1
fi

metadataFile="$1"
pollingTimeoutSec="$2"


if [[ ! -f "$metadataFile" ]]; then
   echo "$metadataFile does not exist."
   exit 1
fi

if [[ ! $pollingTimeoutSec =~ ^[0-9]+$ || $pollingTimeoutSec -le 0 ]]; then
   echo "'$pollingTimeoutSec' is an invalid value for the polling timeout. Please use a positive, non-zero number."
   exit 1
fi

if [[ ! -z "${SONAR_HOST_URL}" ]]; then
   serverUrl="${SONAR_HOST_URL%/}"
   ceTaskUrl="${SONAR_HOST_URL%/}/api$(sed -n 's/^ceTaskUrl=.*api//p' "${metadataFile}")"
else
   serverUrl="$(sed -n 's/serverUrl=\(.*\)/\1/p' "${metadataFile}")"
   ceTaskUrl="$(sed -n 's/ceTaskUrl=\(.*\)/\1/p' "${metadataFile}")"
fi

if [[ -z "${serverUrl}" || -z "${ceTaskUrl}" ]]; then
  echo "Invalid report metadata file."
  exit 1
fi

# Pass --cacert directly per-call instead of editing global ~/.curlrc, so
# subsequent steps in the workflow aren't affected. Cert file is created with
# restrictive perms and cleaned up on exit.
CURL_OPTS=(--location --location-trusted --max-redirs 10 --silent --fail --show-error --user "${SONAR_TOKEN}:")
if [[ -n "${SONAR_ROOT_CERT}" ]]; then
  certFile="$(mktemp)"
  chmod 600 "${certFile}"
  printf '%s' "${SONAR_ROOT_CERT}" > "${certFile}"
  CURL_OPTS+=(--cacert "${certFile}")
  trap 'rm -f "${certFile}"' EXIT
fi

task="$(curl "${CURL_OPTS[@]}" "${ceTaskUrl}")"
status="$(jq -r '.task.status' <<< "$task")"

endTime=$(( ${SECONDS} + ${pollingTimeoutSec} ))

until [[ ${status} != "PENDING" && ${status} != "IN_PROGRESS" || ${SECONDS} -ge ${endTime} ]]; do
    printf '.'
    sleep 5
    task="$(curl "${CURL_OPTS[@]}" "${ceTaskUrl}")"
    status="$(jq -r '.task.status' <<< "$task")"
done
printf '\n'

if [[ ${status} == "PENDING" || ${status} == "IN_PROGRESS" ]] && [[ ${SECONDS} -ge ${endTime} ]]; then
    echo "Polling timeout reached for waiting for finishing of the Sonar scan! Aborting the check for SonarQube's Quality Gate."
    exit 1
fi

analysisId="$(jq -r '.task.analysisId' <<< "${task}")"
qualityGateUrl="${serverUrl}/api/qualitygates/project_status?analysisId=${analysisId}"
qualityGateStatus="$(curl "${CURL_OPTS[@]}" "${qualityGateUrl}" | jq -r '.projectStatus.status')"

dashboardUrl="$(sed -n 's/dashboardUrl=\(.*\)/\1/p' "${metadataFile}")"
analysisResultMsg="Detailed information can be found at: ${dashboardUrl}\n"

if [[ ${qualityGateStatus} == "OK" ]]; then
   set_output "quality-gate-status" "PASSED"
   success "Quality Gate has PASSED."
elif [[ ${qualityGateStatus} == "WARN" ]]; then
   set_output "quality-gate-status" "WARN"
   warn "Warnings on Quality Gate.${reset}\n\n${analysisResultMsg}"
elif [[ ${qualityGateStatus} == "ERROR" ]]; then
   set_output "quality-gate-status" "FAILED"
   fail "Quality Gate has FAILED.${reset}\n\n${analysisResultMsg}"
else
   set_output "quality-gate-status" "FAILED"
   fail "Quality Gate not set for the project. Please configure the Quality Gate in SonarQube or remove sonarqube-quality-gate action from the workflow."
fi

