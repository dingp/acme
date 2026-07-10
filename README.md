# How to setup a Cronjob in Rancher for renewing TLS certificate

There are two different use cases depending on if you have a web server running in your namespace, and if you also have write access to the web root.

## Case 1 - existing web server, write access to web root can be obtained

In this case, you already have a web server and ingress set up in your namespace. Let's assume you are using the following names:

- namespace is `example-ns`;
- workload for the web server is `websrv-wl`;
- ingress is named as `site-ig`;
- your custome domain name is `site-ig.myowndomain.net`
- your web server's web root is on a Persistent Volume with the PVC name as `webroot-pvc` 

Here are the steps you need to setup a cronjob to obtain/update the certificate:
1. Download `kubeconfig` from Rancher webUI (click the "page" icon);
2. Create an Opaque type secret, set the key to `kubeconfig`, and copy the content of the downloaded YAML from the last step in to the Value field;
3. Create a Cronjob:
    - Give it a unique name, and set the schedule to be once every two months, e.g. put `5 12  1 */2 *` in the `Schedule` field;
    - In POD -> Storage, click "Add Volume", select "Persistent Volume Claim", choose the existing volume `webroot-pvc`;
    - In POD -> Security Context, set Filesystem Group to one of your GIDs;
    - In container0 -> Storage, click "Select Volume", add the PVC, mount it to e.g. `/ssl`;
    - In container0 -> Storage, click "Select Volume", add the Secret , mount it to `/kube`;
    - In container0 -> Security Context, drop "ALL" capabilities, set "Run as User ID" to your UID;
    - In container0 -> General:
        * `Container Image` -> `docker.io/dingpf/acme:latest`;
        * `Command` -> `/opt/get_cert_update_ssl_with_websrv.sh`
        * Add the following environment variables:
            - `EMAIL` -> `<your_email>`
            - `DOMAIN` -> `<your domain name>` (multiple domain names can be separated by `:`), e.g. `site-ig.myowndomain.net`; provide only your user-facing domains here. The script derives the internal `*.svc.spin.nersc.org` hostname automatically and excludes it from the certificate request.
            - `KUBECONFIG` -> `/kube/kubeconfig` (assuming you mounted the secret to `/kube` and the secret has the key `kubeconfig`);
            - `CERT_SECRET_NAME` -> `<create a name for your secret holding the TLS certificate>`, you will need to edit your ingress (under 'Certificates') to apply this once the secret is created.
            - `INGRESS_NAME` -> `<your ingress name>` (e.g. `site-ig`)
            - `WEB_ROOT` -> `<path to web root>` (e.g. `/ssl/www` if that's the root directory served by your web server).
    - Click "Save"
4. Once the Cronjob is configured, you can trigger a run by hand, and verify it the settings are correct.
    - In the Workload -> Cronjobs window, click the three dots on the the right side of the page for the newly configured Cronjob, click "Run Now";
    - In the Workload -> Jobs window, you can click on the three dots for the job you just triggered, and select "View Logs" to check if the TLS certificate is issued successfully.

The core functionality is done in the script `/opt/get_cert_update_ssl_with_websrv.sh`. It contains two steps:
1. using `acme.sh`, obtain TLS certificate;
2. using `kubectl`, create/update the secret holding the TLS certificate. 

## Case 2 -- No web server, or no write access to web root

In this case, you will need to create a deployment running a simple web server, serving a directory on a PVC. The script requesting the certificate will do more things:
1. check if there's an existing ingress named `$INGRESS_NAME` in the namespace, if so:
    - download the configuration in JSON format;
    - use `jq` to remove volatile Kubernetes metadata/status while preserving
      labels and useful annotations;
    - save the output into a JSON file, ready to be be reapplied via `kubectl`;
2. prepare a YAML file to configure the ingress for the user-facing domains specified in the `$DOMAIN` environment variable, and also add the auto-created `*.svc.spin.nersc.org` hostname internally for ingress access; the certificate request still excludes that internal hostname;
3. apply the newly prepared ingress via `kubectl` and temporarily remove the
   `nginx.ingress.kubernetes.io/whitelist-source-range` annotation, if present,
   so Let's Encrypt HTTP-01 validation can reach the dummy web server;
4. obtain the TLS certificate;
5. create/update the secret holding the TLS certificate;
6. reapply the original ingress, including its original source allowlist and
   other annotations, if it was set up previously. The script also explicitly
   replays the saved annotations after restoring the Ingress so annotations
   removed for the HTTP-01 challenge are put back reliably.

The detailed steps of setting this up are:
1. create a new Deploymenet for a dummy web server,
    - Workloads -> Deployment, click "Create", give the workload a name, e.g. `dummy-websrv`;
    - In POD -> Storage, click "Add Volume", select "Create Persistent Volume Claim", give it a name, e.g. `webroot-pvc`;
    - In POD -> Security Context, set Filesystem Group to one of your GIDs; 
    - In container0 -> Storage, click "Select Volume", add the PVC, mount it to e.g. `/ssl`;
    - In container0 -> Security Context, drop "ALL" capabilities, set "Run as User ID" to your UID;
    - In container0 -> General:
        * `Container Image` -> `python:latest`
        * Click `Add Port or Service`, `Service Type` -> `ClusterIP`, `Name` -> `<arbitary>` (e.g. `http-dummy-websrv`), `Private Container Port` -> `8080`, `Protocol` -> `TCP`;
        * `Command` -> `python3`, `Arguments` -> `-m http.server 8080`, `Working Dir` -> `/ssl/www`
    - Click `Save`. The web server POD should be running shortly.
2. Download `kubeconfig` from Rancher webUI (click the "page" icon);
3. Create an Opaque type secret by uploading the downloaded kubeconfig file, set the key to `kubeconfig`;
4. Create a Cronjob:
    - Give it a unique name, and set the schedule to be once every two months, e.g. put `5 12  1 */2 *` in the `Schedule` field;
    - In POD -> Storage, click "Add Volume", select "Persistent Volume Claim", choose the existing volume `webroot-pvc`;
    - In POD -> Security Context, set Filesystem Group to one of your GIDs;
    - In container0 -> Storage, click "Select Volume", add the PVC, mount it to e.g. `/ssl`;
    - In container0 -> Storage, click "Select Volume", add the Secret , mount it to `/kube`;
    - In container0 -> Security Context, drop "ALL" capabilities, set "Run as User ID" to your UID;
    - In container0 -> General:
        * `Container Image` -> `docker.io/dingpf/acme:latest`;
        * `Command` -> `/opt/get_cert_update_ssl.sh`
        * Add the following environment variables:
            - `EMAIL` -> `<your_email>`
            - `DOMAIN` -> `<your domain name>` (multiple domain names can be separated by `:`), e.g. `site-ig.myowndomain.net`; provide only your user-facing domains here. The script derives the internal `*.svc.spin.nersc.org` hostname automatically and excludes it from the certificate request.
            - `KUBECONFIG` -> `/kube/kubeconfig` (assuming you mounted the secret to `/kube` and the secret has the key `kubeconfig`);
            - `CERT_SECRET_NAME` -> <create a name for your secret holding the TLS certificate>
            - `INGRESS_NAME` -> `<your ingress name>` (e.g. `site-ig`)
            - `WEB_ROOT` -> `<path to web root>` (e.g. `/ssl/www` if that's the root directory served by your web server),
            - `DUMMY_WEBSERVER` -> `<dummy web server Service name>` (e.g. `dummy-websrv`). This must be the Service name used by the Ingress backend, not necessarily the Deployment/workload name.
        * Optional environment variables:
            - `DUMMY_WEBSERVER_DEPLOYMENT` -> deployment name for the dummy web server to scale if it differs from the `DUMMY_WEBSERVER` Service name; if the Service and Deployment have the same name, you can omit this variable;
            - `DUMMY_WEBSERVER_SCALE_REPLICAS` -> number of replicas to use when temporarily scaling up a dummy web server deployment that is currently at `0` replicas; defaults to `1`;
            - `DUMMY_WEBSERVER_READY_TIMEOUT` -> rollout wait timeout for the dummy web server deployment; defaults to `60s`.
            - `TEMP_INGRESS_REMOVE_ANNOTATIONS` -> comma-separated ingress
              annotations to remove while the temporary challenge ingress is
              active; defaults to
              `nginx.ingress.kubernetes.io/whitelist-source-range`.
    - Click "Save"
4. Once the Cronjob is configured, you can trigger a run by hand, and verify it the settings are correct.
    - In the Workload -> Cronjobs window, click the three dots on the the right side of the page for the newly configured Cronjob, click "Run Now";
    - In the Workload -> Jobs window, you can click on the three dots for the job you just triggered, and select "View Logs" to check if the TLS certificate is issued successfully.

## Additional notes

1. This can be applied when there are multiple web servers in the same namespace. Every web server will need an Ingress controller, and a Cronjob for renewing the TLS certificate.
2. The Ingress controller created by the script in Case 2 can be freely modified later if real web server is added in the namespace. It will not be overwritten but preserved during future runs of the Cronjob.
3. For Case 2, the dummy web server deployment can normally be scaled to `0`. The renewal script records the deployment's original replica count, scales it up only when needed, waits for the rollout to become available, and scales it back to `0` at the end if it started at `0`.

## Using `kubectl`

### Install and config `kubectl`

`kubectl` can be obtained via:

```
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x kubectl
```

The default path to `kubeconfig` is under `$HOME/.kube/config`. One can also specify the path via the `KUBECONFIG` environment variable, or the option `--kubeconfig <path to config file>`. 

### Create a Persistent Volume Claim using dynamic NFS provisioner

Using `kubectl --kubeconfig <path to kubeconfig> apply -f ./mypvc-name.yaml` will create:
1. a Persistent Volume Claim (PVC) named "mypvc-name" using the `nfs-client` storage class;
2. a Persistent Volume pointing to a newly created directory on the NFS server will be created and associated to the PVC;
3. the PV has a size of 1GiB as requested by the PVC.

Here is the content of `mypvc-name.yaml`. You may change the values of `metadata.name`, `metadata.namespace` and `spec.resources.requests.storage`.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mypvc-name
  namespace: my-namespace
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-client
  volumeMode: Filesystem
```

### Create a Deployment

The following YAML specifies a Deployment which 
1. has one container named `container-0` running in its POD;
2. `container-0` is run as the user with the specified UID `<my UID>`;
3. uses the `mypvc-name` PVC created above, and mount it to `/www` in `container-0`;
4. runs a web server with python to serve the `/www` directory in `container-0`.

Use `kubectl apply -f <path to yaml>` to create the deployment.

Note that you will need to change strings like `my-namespace`, `my-workload`, `mypvc-name`, `vol-mypvc`, and replace `<my UID>` and `<my GID>` in the YAML first.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
  labels:
    workloadselector: my-namespace-my-workload
  name: my-workload
  namespace: my-namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      workloadselector: my-namespace-my-workload
  template:
    metadata:
      labels:
        workloadselector: my-namespace-my-workload
      namespace: my-namespace
    spec:
      containers:
      - args:
        - -m
        - http.server
        - "8080"
        command:
        - python3
        image: python:latest
        imagePullPolicy: Always
        name: container-0
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        resources: {}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          privileged: false
          readOnlyRootFilesystem: false
          runAsNonRoot: false
          runAsUser: <my UID>
        volumeMounts:
        - mountPath: /www
          name: vol-mypvc
        workingDir: /www
      securityContext:
        fsGroup: <my GID>
      volumes:
      - name: vol-mypvc
        persistentVolumeClaim:
          claimName: mypvc-name
```

### Create a secret for `kubeconfig`

This can be done via:

```
 kubectl -n <my-namespace> create secret generic <secret name> --from-file=kubeconfig=<path to kubeconfig file>
```

Fill in `<secret name>` and `<path to kubeconfig file>` accordingly.

### Create an 



### Create a Cronjob
