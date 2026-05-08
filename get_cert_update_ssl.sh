#!/bin/bash

check_env_variable() {
	if [ -z "${!1}" ]; then
		echo "Error: $1 environment variable is not set."
		exit 1
	fi
}
restore_existing_ingress() {
	if [ -f /tmp/existing_ingress.json ]; then
		/opt/kubectl apply -f /tmp/existing_ingress.json
	fi
}

scale_down_dummy_webserver_if_needed() {
	if [ "${SCALED_DUMMY_WEBSERVER:-false}" = "true" ] && [ "${ORIGINAL_DUMMY_WEBSERVER_REPLICAS:-}" = "0" ]; then
		echo "Info: scaling dummy webserver deployment ${DUMMY_WEBSERVER_DEPLOYMENT} back to 0 replicas"
		/opt/kubectl -n "${NAMESPACE}" scale deployment "${DUMMY_WEBSERVER_DEPLOYMENT}" --replicas=0
	fi
}

cleanup() {
	restore_existing_ingress
	scale_down_dummy_webserver_if_needed
}

ensure_dummy_webserver_ready() {
	if ! /opt/kubectl get deployment -n "${NAMESPACE}" "${DUMMY_WEBSERVER_DEPLOYMENT}" >/dev/null 2>&1; then
		echo "Error: dummy webserver deployment ${DUMMY_WEBSERVER_DEPLOYMENT} was not found in namespace ${NAMESPACE}."
		echo "Error: DUMMY_WEBSERVER_DEPLOYMENT controls the Kubernetes Deployment name checked here; DUMMY_WEBSERVER is the dummy webserver Service / Ingress backend name. Set DUMMY_WEBSERVER_DEPLOYMENT if the Deployment name differs from the Service name."
		exit 1
	fi

	ORIGINAL_DUMMY_WEBSERVER_REPLICAS=$(/opt/kubectl get deployment -n "${NAMESPACE}" "${DUMMY_WEBSERVER_DEPLOYMENT}" -o jsonpath='{.spec.replicas}')
	if [ -z "${ORIGINAL_DUMMY_WEBSERVER_REPLICAS}" ]; then
		ORIGINAL_DUMMY_WEBSERVER_REPLICAS=1
	fi

	if [ "${ORIGINAL_DUMMY_WEBSERVER_REPLICAS}" = "0" ]; then
		echo "Info: dummy webserver deployment ${DUMMY_WEBSERVER_DEPLOYMENT} is scaled to 0; scaling to ${DUMMY_WEBSERVER_SCALE_REPLICAS}"
		if ! /opt/kubectl -n "${NAMESPACE}" scale deployment "${DUMMY_WEBSERVER_DEPLOYMENT}" --replicas="${DUMMY_WEBSERVER_SCALE_REPLICAS}"; then
			echo "Error: failed to scale dummy webserver deployment ${DUMMY_WEBSERVER_DEPLOYMENT}."
			exit 1
		fi
		SCALED_DUMMY_WEBSERVER=true
	else
		echo "Info: dummy webserver deployment ${DUMMY_WEBSERVER_DEPLOYMENT} already has ${ORIGINAL_DUMMY_WEBSERVER_REPLICAS} replicas configured."
	fi

	echo "Info: waiting for dummy webserver deployment ${DUMMY_WEBSERVER_DEPLOYMENT} to become available"
	if ! /opt/kubectl -n "${NAMESPACE}" rollout status deployment "${DUMMY_WEBSERVER_DEPLOYMENT}" --timeout="${DUMMY_WEBSERVER_READY_TIMEOUT}"; then
		echo "Error: dummy webserver deployment ${DUMMY_WEBSERVER_DEPLOYMENT} did not become ready within ${DUMMY_WEBSERVER_READY_TIMEOUT}."
		exit 1
	fi
}

check_env_variable "EMAIL"
check_env_variable "DOMAIN"
check_env_variable "KUBECONFIG"
check_env_variable "CERT_SECRET_NAME"
check_env_variable "INGRESS_NAME"
check_env_variable "WEB_ROOT"
check_env_variable "DUMMY_WEBSERVER"


NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
CLUSTER=$(/opt/kubectl config current-context)
FIRST_DOMAIN=$(echo $DOMAIN | cut -d':' -f1)
USER_DOMAIN_LIST=$DOMAIN
SPIN_DOMAIN=$INGRESS_NAME.$NAMESPACE.${CLUSTER}.svc.spin.nersc.org
DUMMY_WEBSERVER_DEPLOYMENT=${DUMMY_WEBSERVER_DEPLOYMENT:-$DUMMY_WEBSERVER}
DUMMY_WEBSERVER_SCALE_REPLICAS=${DUMMY_WEBSERVER_SCALE_REPLICAS:-1}
DUMMY_WEBSERVER_READY_TIMEOUT=${DUMMY_WEBSERVER_READY_TIMEOUT:-60s}
SCALED_DUMMY_WEBSERVER=false
ORIGINAL_DUMMY_WEBSERVER_REPLICAS=""

trap cleanup EXIT

if [[ $USER_DOMAIN_LIST == *:* ]]; then
	IFS=':' read -ra DOMAIN_ARRAY <<< "$USER_DOMAIN_LIST"
else
	DOMAIN_ARRAY=("$USER_DOMAIN_LIST")
fi

if [[ ! " ${DOMAIN_ARRAY[@]} " =~ " ${SPIN_DOMAIN} " ]]; then
	DOMAIN_ARRAY+=("${SPIN_DOMAIN}")
fi

# create ingress yaml for issuing TLS certificate
cat <<EOF > /tmp/ssl_ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
spec:
  ingressClassName: nginx
  rules:
EOF

for domain in "${DOMAIN_ARRAY[@]}"; do
cat <<EOF >> /tmp/ssl_ingress.yaml
    - host: $domain
      http:
        paths:
          - backend:
              service:
                name: ${DUMMY_WEBSERVER}
                port:
                  number: 8080
            path: /
            pathType: Prefix
EOF
done

ensure_dummy_webserver_ready

# Backup existing ingress
# Check if ingress controller exists
if ! /opt/kubectl get ingress -n ${NAMESPACE} ${INGRESS_NAME} >/dev/null 2>&1; then
  echo "Info: Ingress not found, will keep new ingress"
else
	echo "Info: ingress found, backup"
	/opt/kubectl get ingress -n ${NAMESPACE} ${INGRESS_NAME} -o json |jq 'del(
    .metadata.annotations,
    .metadata.creationTimestamp,
    .metadata.generation,
    .metadata.labels,
    .metadata.resourceVersion,
    .metadata.uid,
    .status,
    .metadata.__clone
)' > /tmp/existing_ingress.json
fi

# Apply new ingress for issuing TLS certificate
if ! /opt/kubectl apply -f /tmp/ssl_ingress.yaml; then
	echo "Error: failed to apply temporary ingress for issuing TLS certificate."
	exit 1
fi

echo "sleep for 10s for the ingress change to propagate"
sleep 10

# Obtain certificate
for domain in "${DOMAIN_ARRAY[@]}"; do
	if [[ "$domain" == "$SPIN_DOMAIN" ]]; then
		continue
	fi
	if ! curl --head --silent --fail "$domain"; then
		echo "Error: Domain $domain does not exist."
		echo "Error: Please make sure the domain is correct and accessible."
		echo "Error: If the domain is correct, please make sure you wait enough time for the DNS to reflect the change."
		echo "Error: you can use 'dig +short $domain' to check the IP address of the domain."
		exit 1
	fi
	ACME_DOMAINS+=" -d $domain"
done

ACME_HOME=/tmp/acme
/opt/acme/acme.sh \
	--register-account -m $EMAIL \
	--home $ACME_HOME \
	--issue -f \
	${ACME_DOMAINS} \
	--server letsencrypt \
	-w ${WEB_ROOT}

# exit 1 if the previous command fails
if [ $? -ne 0 ]; then
	echo "Error: obtaining certificate from Let's Encrypt failed."
	exit 1
fi

CERT_PATH=$ACME_HOME/${FIRST_DOMAIN}_ecc/fullchain.cer
KEY_PATH=$ACME_HOME/${FIRST_DOMAIN}_ecc/${FIRST_DOMAIN}.key

# update TLS secret
if [[ -f $CERT_PATH && -f $KEY_PATH ]]; then
	/opt/kubectl \
		-n ${NAMESPACE} \
		create secret tls ${CERT_SECRET_NAME} \
		--cert=$CERT_PATH \
		--key=${KEY_PATH} \
		--dry-run=client --save-config -o yaml | \
		/opt/kubectl apply -f -
else
	echo "Error: $CERT_PATH or $KEY_PATH does not exist."
	exit 1
fi
