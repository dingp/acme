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
2. Create an Opaque type secret by uploading the downloaded kubeconfig file, set the key to `kubeconfig`;
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
            - `DOMAIN` -> `<your domain name>` (multiple domain names can be separated by `:`), e.g. `site-ig.myowndomain.net;site-ig.example-ns.development.svc.spin.nersc.org`;
            - `KUBECONFIG` -> `/kube/kubeconfig` (assuming you mounted the secret to `/kube` and the secret has the key `kubeconfig`);
            - `CERT_SECRET_NAME` -> <create a name for your secret holding the TLS certificate>
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
    - use `jq` to remove Rancher's annotations/status;
    - save the output into a JSON file, ready to be be reapplied via `kubectl`;
2. prepare a YAML file to configure the ingress for the domain names specified in the `$DOMAIN` environment variable;
3. apply the newly prepared ingress via `kubectl`;
4. obtain the TLS certificate;
5. create/update the secret holding the TLS certificate;
6. reapply the original ingress if it was set up previously.

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
            - `DOMAIN` -> `<your domain name>` (multiple domain names can be separated by `:`), e.g. `site-ig.myowndomain.net;site-ig.example-ns.development.svc.spin.nersc.org`;
            - `KUBECONFIG` -> `/kube/kubeconfig` (assuming you mounted the secret to `/kube` and the secret has the key `kubeconfig`);
            - `CERT_SECRET_NAME` -> <create a name for your secret holding the TLS certificate>
            - `INGRESS_NAME` -> `<your ingress name>` (e.g. `site-ig`)
            - `WEB_ROOT` -> `<path to web root>` (e.g. `/ssl/www` if that's the root directory served by your web server),
            - `DUMMY_WEBSERVER` -> `<Work load name from step 1>` (e.g. `dummy-websrv`)
    - Click "Save"
4. Once the Cronjob is configured, you can trigger a run by hand, and verify it the settings are correct.
    - In the Workload -> Cronjobs window, click the three dots on the the right side of the page for the newly configured Cronjob, click "Run Now";
    - In the Workload -> Jobs window, you can click on the three dots for the job you just triggered, and select "View Logs" to check if the TLS certificate is issued successfully.

## Additional notes

1. This can be applied when there are multiple web servers in the same namespace. Every web server will need an Ingress controller, and a Cronjob for renewing the TLS certificate.
2. The Ingress controller created by the script in Case 2 can be freely modified later if real web server is added in the namespace. It will not be overwritten but preserved during future runs of the Cronjob.