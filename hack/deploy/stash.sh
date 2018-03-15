#!/bin/bash
set -eou pipefail

crds=(restics recoveries)

echo "checking kubeconfig context"
kubectl config current-context || { echo "Set a context (kubectl use-context <context>) out of the following:"; echo; kubectl config get-contexts; exit 1; }
echo ""

# https://stackoverflow.com/a/677212/244009
if [ -x "$(command -v onessl >/dev/null 2>&1)" ]; then
    export ONESSL=onessl
else
    # ref: https://stackoverflow.com/a/27776822/244009
    case "$(uname -s)" in
        Darwin)
            curl -fsSL -o onessl https://github.com/kubepack/onessl/releases/download/0.1.0/onessl-darwin-amd64
            chmod +x onessl
            export ONESSL=./onessl
            ;;

        Linux)
            curl -fsSL -o onessl https://github.com/kubepack/onessl/releases/download/0.1.0/onessl-linux-amd64
            chmod +x onessl
            export ONESSL=./onessl
            ;;

        CYGWIN*|MINGW32*|MSYS*)
            curl -fsSL -o onessl.exe https://github.com/kubepack/onessl/releases/download/0.1.0/onessl-windows-amd64.exe
            chmod +x onessl.exe
            export ONESSL=./onessl.exe
            ;;
        *)
            echo 'other OS'
            ;;
    esac
fi

# http://redsymbol.net/articles/bash-exit-traps/
function cleanup {
    rm -rf $ONESSL ca.crt ca.key server.crt server.key
}
trap cleanup EXIT

# ref: https://stackoverflow.com/a/7069755/244009
# ref: https://jonalmeida.com/posts/2013/05/26/different-ways-to-implement-flags-in-bash/
# ref: http://tldp.org/LDP/abs/html/comparison-ops.html

export STASH_NAMESPACE=kube-system
export STASH_SERVICE_ACCOUNT=stash-operator
export STASH_ENABLE_RBAC=true
export STASH_RUN_ON_MASTER=0
export STASH_ENABLE_INITIALIZER=false
export STASH_ENABLE_ADMISSION_WEBHOOK=false
export STASH_DOCKER_REGISTRY=appscode
export STASH_IMAGE_PULL_SECRET=
export STASH_UNINSTALL=0
export STASH_PURGE=0

KUBE_APISERVER_VERSION=$(kubectl version -o=json | $ONESSL jsonpath '{.serverVersion.gitVersion}')
$ONESSL semver --check='>=1.9.0' $KUBE_APISERVER_VERSION
if [ $? -eq 0 ]; then
    export STASH_ENABLE_ADMISSION_WEBHOOK=true
fi

show_help() {
    echo "stash.sh - install stash operator"
    echo " "
    echo "stash.sh [options]"
    echo " "
    echo "options:"
    echo "-h, --help                         show brief help"
    echo "-n, --namespace=NAMESPACE          specify namespace (default: kube-system)"
    echo "    --rbac                         create RBAC roles and bindings (default: true)"
    echo "    --docker-registry              docker registry used to pull stash images (default: appscode)"
    echo "    --image-pull-secret            name of secret used to pull stash operator images"
    echo "    --run-on-master                run stash operator on master"
    echo "    --enable-admission-webhook     configure admission webhook for stash CRDs"
    echo "    --enable-initializer           configure stash operator as workload initializer"
    echo "    --uninstall                    uninstall stash"
    echo "    --purge                        purges stash crd objects and crds"
}

while test $# -gt 0; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -n)
            shift
            if test $# -gt 0; then
                export STASH_NAMESPACE=$1
            else
                echo "no namespace specified"
                exit 1
            fi
            shift
            ;;
        --namespace*)
            export STASH_NAMESPACE=`echo $1 | sed -e 's/^[^=]*=//g'`
            shift
            ;;
        --docker-registry*)
            export STASH_DOCKER_REGISTRY=`echo $1 | sed -e 's/^[^=]*=//g'`
            shift
            ;;
        --image-pull-secret*)
            secret=`echo $1 | sed -e 's/^[^=]*=//g'`
            export STASH_IMAGE_PULL_SECRET="name: '$secret'"
            shift
            ;;
        --enable-admission-webhook*)
            val=`echo $1 | sed -e 's/^[^=]*=//g'`
            if [ "$val" = "false" ]; then
                export STASH_ENABLE_ADMISSION_WEBHOOK=false
            else
                export STASH_ENABLE_ADMISSION_WEBHOOK=true
            fi
            shift
            ;;
        --enable-initializer)
            export STASH_ENABLE_INITIALIZER=true
            shift
            ;;
        --rbac*)
            val=`echo $1 | sed -e 's/^[^=]*=//g'`
            if [ "$val" = "false" ]; then
                export STASH_SERVICE_ACCOUNT=default
                export STASH_ENABLE_RBAC=false
            fi
            shift
            ;;
        --run-on-master)
            export STASH_RUN_ON_MASTER=1
            shift
            ;;
        --uninstall)
            export STASH_UNINSTALL=1
            shift
            ;;
        --purge)
            export STASH_PURGE=1
            shift
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
done

if [ "$STASH_UNINSTALL" -eq 1 ]; then
    kubectl delete deployment -l app=stash --namespace $STASH_NAMESPACE
    kubectl delete service -l app=stash --namespace $STASH_NAMESPACE
    kubectl delete secret -l app=stash --namespace $STASH_NAMESPACE
    kubectl delete validatingwebhookconfiguration -l app=stash --namespace $STASH_NAMESPACE
    kubectl delete mutatingwebhookconfiguration -l app=stash --namespace $STASH_NAMESPACE
    kubectl delete apiservice -l app=stash --namespace $STASH_NAMESPACE
    # Delete RBAC objects, if --rbac flag was used.
    kubectl delete serviceaccount -l app=stash --namespace $STASH_NAMESPACE
    kubectl delete clusterrolebindings -l app=stash --namespace $STASH_NAMESPACE
    kubectl delete clusterrole -l app=stash --namespace $STASH_NAMESPACE
    kubectl delete rolebindings -l app=stash --namespace $STASH_NAMESPACE
    kubectl delete role -l app=stash --namespace $STASH_NAMESPACE

    echo "waiting for stash operator pod to stop running"
    for (( ; ; )); do
       pods=($(kubectl get pods --all-namespaces -l app=stash -o jsonpath='{range .items[*]}{.metadata.name} {end}'))
       total=${#pods[*]}
        if [ $total -eq 0 ] ; then
            break
        fi
       sleep 2
    done

    # https://github.com/kubernetes/kubernetes/issues/60538
    if [ "$STASH_PURGE" -eq 1 ]; then
        for crd in "${crds[@]}"; do
            pairs=($(kubectl get ${crd}.stash.appscode.com --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.namespace} {end}' || true))
            total=${#pairs[*]}

            # save objects
            if [ $total -gt 0 ]; then
                echo "dumping ${crd} objects into ${crd}.yaml"
                kubectl get ${crd}.stash.appscode.com --all-namespaces -o yaml > ${crd}.yaml
            fi

            for (( i=0; i<$total; i+=2 )); do
                name=${pairs[$i]}
                namespace=${pairs[$i + 1]}
                # delete crd object
                echo "deleting ${crd} $namespace/$name"
                kubectl delete ${crd}.stash.appscode.com $name -n $namespace
            done

            # delete crd
            kubectl delete crd ${crd}.stash.appscode.com || true
        done
    fi

    echo
    echo "Successfully uninstalled Stash!"
    exit 0
fi

echo "checking whether extended apiserver feature is enabled"
$ONESSL has-keys configmap --namespace=kube-system --keys=requestheader-client-ca-file extension-apiserver-authentication || { echo "Set --requestheader-client-ca-file flag on Kubernetes apiserver"; exit 1; }
echo ""

env | sort | grep STASH*
echo ""

# create necessary TLS certificates:
# - a local CA key and cert
# - a webhook server key and cert signed by the local CA
$ONESSL create ca-cert
$ONESSL create server-cert server --domains=stash-operator.$STASH_NAMESPACE.svc
export SERVICE_SERVING_CERT_CA=$(cat ca.crt | $ONESSL base64)
export TLS_SERVING_CERT=$(cat server.crt | $ONESSL base64)
export TLS_SERVING_KEY=$(cat server.key | $ONESSL base64)
export KUBE_CA=$($ONESSL get kube-ca | $ONESSL base64)

curl -fsSL https://raw.githubusercontent.com/appscode/stash/0.7.0-rc.0/hack/deploy/operator.yaml | $ONESSL envsubst | kubectl apply -f -

if [ "$STASH_ENABLE_RBAC" = true ]; then
    kubectl create serviceaccount $STASH_SERVICE_ACCOUNT --namespace $STASH_NAMESPACE
    kubectl label serviceaccount $STASH_SERVICE_ACCOUNT app=stash --namespace $STASH_NAMESPACE
    curl -fsSL https://raw.githubusercontent.com/appscode/stash/0.7.0-rc.0/hack/deploy/rbac-list.yaml | $ONESSL envsubst | kubectl auth reconcile -f -
    curl -fsSL https://raw.githubusercontent.com/appscode/stash/0.7.0-rc.0/hack/deploy/user-roles.yaml | $ONESSL envsubst | kubectl auth reconcile -f -

fi

if [ "$STASH_RUN_ON_MASTER" -eq 1 ]; then
    kubectl patch deploy stash-operator -n $STASH_NAMESPACE \
      --patch="$(curl -fsSL https://raw.githubusercontent.com/appscode/stash/0.7.0-rc.0/hack/deploy/run-on-master.yaml)"
fi

if [ "$STASH_ENABLE_INITIALIZER" = true ]; then
    kubectl apply -f https://raw.githubusercontent.com/appscode/stash/0.7.0-rc.0/hack/deploy/initializer.yaml
fi

if [ "$STASH_ENABLE_ADMISSION_WEBHOOK" = true ]; then
    curl -fsSL https://raw.githubusercontent.com/appscode/stash/0.7.0-rc.0/hack/deploy/admission.yaml | $ONESSL envsubst | kubectl apply -f -
fi

echo
echo "waiting until stash operator deployment is ready"
$ONESSL wait-until-ready deployment stash-operator --namespace $STASH_NAMESPACE || { echo "Stash operator deployment failed to be ready"; exit 1; }

echo "waiting until stash apiservice is available"
$ONESSL wait-until-ready apiservice v1alpha1.admission.stash.appscode.com || { echo "Stash apiservice failed to be ready"; exit 1; }

echo "waiting until stash crds are ready"
for crd in "${crds[@]}"; do
    $ONESSL wait-until-ready crd ${crd}.stash.appscode.com || { echo "$crd crd failed to be ready"; exit 1; }
done

echo
echo "Successfully installed Stash!"