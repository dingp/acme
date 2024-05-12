#!/bin/bash

check_env_variable() {
	if [ -z "${!1}" ]; then
		echo "Error: $1 environment variable is not set."
		exit 1
	fi
}

check_env_variable "EMAIL"
check_env_variable "DOMAIN"
check_env_variable "KUBECONFIG"
check_env_variable "CERT_SECRET_NAME"
check_env_variable "WEB_ROOT"
check_env_variable "INGRESS_NAME"
check_env_variable "ACME_HOME"

NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
CLUSTER=$(/opt/kubectl config current-context)
FIRST_DOMAIN=$(echo $DOMAIN | cut -d':' -f1)
DEFAULT_DOMAIN=$INGRESS_NAME.$NAMESPACE.${CLUSTER}.svc.spin.nersc.org

if [[ $DOMAIN == *:* ]]; then
	IFS=':' read -ra DOMAIN_ARRAY <<< "$DOMAIN"
else
	DOMAIN_ARRAY=("$DOMAIN")
fi

if [[ ! " ${DOMAIN_ARRAY[@]} " =~ " ${DEFAULT_DOMAIN} " ]]; then
	DOMAIN_ARRAY+=("${DEFAULT_DOMAIN}")
fi

# Obtain certificate
for domain in "${DOMAIN_ARRAY[@]}"; do
	ACME_DOMAINS+=" -d $domain"
done

CERT_PATH=$ACME_HOME/${FIRST_DOMAIN}_ecc/fullchain.cer
KEY_PATH=$ACME_HOME/${FIRST_DOMAIN}_ecc/${FIRST_DOMAIN}.key

if ! [ -f $CERT_PATH ]; then
  /opt/acme/acme.sh --install -m $EMAIL
fi


/opt/acme/acme.sh \
	--register-account -m $EMAIL \
	--home $ACME_HOME \
	--issue -f \
	${ACME_DOMAINS} \
	--server letsencrypt \
	-w ${WEB_ROOT}

# update TLS secret
/opt/kubectl \
	-n ${NAMESPACE} \
	create secret tls ${CERT_SECRET_NAME} \
	--cert=$CERT_PATH \
	--key=${KEY_PATH} \
	--dry-run=client --save-config -o yaml | \
	/opt/kubectl apply -f -
