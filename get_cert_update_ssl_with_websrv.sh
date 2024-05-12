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
ACME_HOME=/tmp/acme

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
	if ! curl --head --silent --fail "$domain"; then
		echo "Error: Domain $domain does not exist."
		echo "Error: Please make sure the domain is correct and accessible."
		echo "Error: If the domain is correct, please make sure you wait enough time for the DNS to reflect the change."
		echo "Error: you can use 'dig +short $domain' to check the IP address of the domain."
		exit 1
	fi
	ACME_DOMAINS+=" -d $domain"
done

CERT_PATH=$ACME_HOME/${FIRST_DOMAIN}_ecc/fullchain.cer
KEY_PATH=$ACME_HOME/${FIRST_DOMAIN}_ecc/${FIRST_DOMAIN}.key

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