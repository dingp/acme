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
check_env_variable "INGRESS_NAME"
check_env_variable "WEB_ROOT"
check_env_variable "DUMMY_WEBSERVER"


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

# Create ingress yaml for issuing TLS certificate
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

cat <<EOF >> /tmp/ssl_ingress.yaml
  tls:
    - hosts:
        - ${FIRST_DOMAIN}
      secretName: ${CERT_SECRET_NAME}
EOF

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
  cp /tmp/existing_ingress.json /ssl
fi


 cp /tmp/ssl_ingress.yaml /ssl
# Apply new ingress for issuing TLS certificate
/opt/kubectl apply -f /tmp/ssl_ingress.yaml

# wait for one minutes
#sleep 59

# Obtain certificate
for domain in "${DOMAIN_ARRAY[@]}"; do
	ACME_DOMAINS+=" -d $domain"
done

/opt/acme/acme.sh \
	--register-account -m $EMAIL \
	--home /tmp/acme \
	--issue -f \
	${ACME_DOMAINS} \
	--server letsencrypt \
	-w ${WEB_ROOT}

CERT_PATH=/tmp/acme/${FIRST_DOMAIN}_ecc/fullchain.cer
KEY_PATH=/tmp/acme/${FIRST_DOMAIN}_ecc/${FIRST_DOMAIN}.key

# update TLS secret
/opt/kubectl \
	-n ${NAMESPACE} \
	create secret tls ${CERT_SECRET_NAME} \
	--cert=$CERT_PATH \
	--key=${KEY_PATH} \
	--dry-run=client --save-config -o yaml | \
	/opt/kubectl apply -f -

# Restore ingress if it exists
if [ -f /tmp/existing_ingress.json ]; then
	/opt/kubectl apply -f /tmp/existing_ingress.json
fi
