#!/bin/bash
# import helpers
. scripts/common.sh

# get config
loadenv ./.env

# Create cluster and registry
k3d registry create backstack.localhost --port 5000
k3d cluster create backstack --registry-use k3d-backstack.localhost:5000 --agents 1 -p 80:80@agent:0 -p 443:443@agent:0

# Export docker default platform. The configuration will not install with arm
# plaform architecture
export DOCKER_DEFAULT_PLATFORM=linux/amd64

if [[ -z $(docker image ls --format json | jq '.. | strings | select(contains("k3d-backstack.localhost:5000/backstage"))') ]]; then
  npm install --global yarn
  # Build local backstage image & push it to k3d registry. Image previously used was only compatible with arm64
  cd backstage
  yarn install --frozen-lockfile
  yarn tsc
  yarn build:backend --config ../../app-config.yaml
  docker image build . -f packages/backend/Dockerfile --tag k3d-backstack.localhost:5000/backstage
fi
docker push k3d-backstack.localhost:5000/backstage

# Build local crossplane config
crossplane build configuration --package-root=crossplane --name=backstack.xpkg
#1,14 command
#crossplane xpkg build --package-file=crossplane/backstack.xpkg --package-root=crossplane
# Push local crossplane config to local registry
#1.14 command
#crossplane xpkg push -f crossplane/backstack.xpkg "localhost:5000/backstack:0.0.1"
crossplane push configuration --package crossplane/backstack.xpkg "localhost:5000/backstack:0.0.1"

# configure ingress
#kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/cloud/deploy.yaml
#kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s 

# install crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm upgrade --install crossplane --namespace crossplane-system --create-namespace crossplane-stable/crossplane --set args='{--enable-external-secret-stores}' --wait

# install vault ess plugin
helm upgrade --install ess-plugin-vault oci://xpkg.upbound.io/crossplane-contrib/ess-plugin-vault --namespace crossplane-system --set-json podAnnotations='{"vault.hashicorp.com/agent-inject": "true", "vault.hashicorp.com/agent-inject-token": "true", "vault.hashicorp.com/role": "crossplane", "vault.hashicorp.com/agent-run-as-user": "65532"}'

waitfor default crd configurations.pkg.crossplane.io

# install back stack
kubectl apply -f - <<-EOF
    apiVersion: pkg.crossplane.io/v1
    kind: Configuration
    metadata:
      name: back-stack
    spec:
      package: k3d-backstack.localhost:5000/backstack:0.0.1
EOF


# configure provider-helm for crossplane
waitfor default crd providerconfigs.helm.crossplane.io
kubectl wait crd/providerconfigs.helm.crossplane.io --for=condition=Established --timeout=1m
SA=$(kubectl -n crossplane-system get sa -o name | grep provider-helm | sed -e 's|serviceaccount\/|crossplane-system:|g')
kubectl create clusterrolebinding provider-helm-admin-binding --clusterrole cluster-admin --serviceaccount="${SA}"
kubectl create -f - <<- EOF
    apiVersion: helm.crossplane.io/v1beta1
    kind: ProviderConfig
    metadata:
      name: local
    spec:
      credentials:
        source: InjectedIdentity
EOF

# configure provider-kubernetes for crossplane
waitfor default crd providerconfigs.kubernetes.crossplane.io
kubectl wait crd/providerconfigs.kubernetes.crossplane.io --for=condition=Established --timeout=1m
SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed -e 's|serviceaccount\/|crossplane-system:|g')
kubectl create clusterrolebinding provider-kubernetes-admin-binding --clusterrole cluster-admin --serviceaccount="${SA}"
kubectl create -f - <<- EOF
    apiVersion: kubernetes.crossplane.io/v1alpha1
    kind: ProviderConfig
    metadata:
      name: local
    spec:
      credentials:
        source: InjectedIdentity
EOF

# configure provider-azure for crossplane
# waitfor default crd providerconfigs.azure.upbound.io
#kubectl wait crd/providerconfigs.azure.upbound.io --for=condition=Established --timeout=1m
#kubectl create -f - <<- EOF
#    apiVersion: azure.upbound.io/v1beta1
#    kind: ProviderConfig
#    metadata:
#      name: default
#    spec:
#      credentials:
#        source: Secret
#        secretRef:
#          namespace: crossplane-system
#          name: azure-secret
#          key: credentials    
#EOF

# configure provider-aws for crossplane
waitfor default crd providerconfigs.aws.upbound.io
kubectl wait crd/providerconfigs.aws.upbound.io --for=condition=Established --timeout=1m
kubectl create -f - <<- EOF
    apiVersion: aws.upbound.io/v1beta1
    kind: ProviderConfig
    metadata:
      name: default
    spec:
      credentials:
        source: Secret
        secretRef:
          namespace: crossplane-system
          name: aws-secret
          key: credentials
EOF

# deploy hub
waitfor default crd hubs.backstack.cncf.io
kubectl wait crd/hubs.backstack.cncf.io --for=condition=Established --timeout=1m
kubectl apply -f - <<-EOF
    apiVersion: backstack.cncf.io/v1alpha1
    kind: Hub
    metadata:
      name: hub
    spec: 
      parameters:
        clusterId: local
        repository: ${REPOSITORY}
        backstage:
          host: backstage-7f000001.nip.io
        argocd:
          host: argocd-7f000001.nip.io
        vault:
          host: vault-7f000001.nip.io
EOF

# deploy secrets
waitfor default ns argocd
kubectl create -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: repo-creds
      namespace: argocd
      labels:
        argocd.argoproj.io/secret-type: repo-creds
    stringData:
      type: git
      url: ${GITHUB_ORG}
      password: ${GITHUB_TOKEN}
      username: back-stack
EOF

kubectl create -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: back-stack-repo
      namespace: argocd
      labels:
        argocd.argoproj.io/secret-type: repository
    stringData:
      type: git
      url: ${REPOSITORY}
EOF

waitfor default ns backstage
kubectl create -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: backstage
      namespace: backstage
    stringData:
      GITHUB_TOKEN: ${GITHUB_TOKEN}
      VAULT_TOKEN: ${VAULT_TOKEN}
EOF

#kubectl create -f - <<-EOF
#    apiVersion: v1
#    kind: Secret
#    metadata:
#      name: azure-secret
#      namespace: crossplane-system
#    stringData:
#      credentials: |
#        ${AZURE_CREDENTIALS}
#EOF

kubectl create -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: aws-secret
      namespace: crossplane-system
    stringData:
      credentials: |
        [default]
        aws_access_key_id=${AWS_ACCESS_KEY_ID}
        aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
        aws_session_token=${AWS_SESSION_TOKEN}
EOF


waitfor argocd secret argocd-initial-admin-secret
ARGO_INITIAL_PASSWORD=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

# configure vault
kubectl wait -n vault pod/vault-0 --for=condition=Ready --timeout=1m
kubectl -n vault exec -i vault-0 -- vault auth enable kubernetes
kubectl -n vault exec -i vault-0 -- sh -c 'vault write auth/kubernetes/config \
        token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
kubectl -n vault exec -i vault-0 -- vault policy write crossplane - <<EOF
path "secret/data/*" {
    capabilities = ["create", "read", "update", "delete"]
}
path "secret/metadata/*" {
    capabilities = ["create", "read", "update", "delete"]
}
EOF
kubectl -n vault exec -i vault-0 -- vault write auth/kubernetes/role/crossplane \
    bound_service_account_names="*" \
    bound_service_account_namespaces=crossplane-system \
    policies=crossplane \
    ttl=24h

# restart ess pod
kubectl get -n crossplane-system pods -o name | grep ess-plugin-vault | xargs kubectl delete -n crossplane-system 

# ready to go!
echo ""
echo "
Your BACK Stack is ready!

Backstage: https://backstage-7f000001.nip.io
ArgoCD: https://argocd-7f000001.nip.io
  username: admin
  password ${ARGO_INITIAL_PASSWORD}
"
