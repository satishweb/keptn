
function setup_gcloud {
    if [ ! -d "$HOME/google-cloud-sdk/bin" ]; then rm -rf $HOME/google-cloud-sdk; export CLOUDSDK_CORE_DISABLE_PROMPTS=1; curl https://sdk.cloud.google.com | bash; fi
    source /home/travis/google-cloud-sdk/path.bash.inc
    gcloud --quiet version
    gcloud --quiet components update
    gcloud --quiet components update kubectl
    echo $GCLOUD_SERVICE_KEY | base64 --decode -i > ${HOME}/gcloud-service-key.json
    gcloud auth activate-service-account --key-file ${HOME}/gcloud-service-key.json
}

function setup_glcoud_pr {
    gcloud --quiet config set project $PROJECT_NAME
    gcloud container clusters get-credentials $CLUSTER_PR_STATUSCHECK_NAME --zone $CLUSTER_PR_STATUSCHECK_ZONE --project $PROJECT_NAME
    export GCLOUD_USER=$(gcloud config get-value account)

    kubectl create clusterrolebinding travis-cluster-admin-binding --clusterrole=cluster-admin --user=$GCLOUD_USER || true
    # export REGISTRY_URL=$(kubectl describe svc docker-registry -n keptn | grep "IP:" | sed 's~IP:[ \t]*~~')
}

function setup_gcloud_nightly {
    gcloud --quiet config set project $PROJECT_NAME
    gcloud --quiet config set container/cluster $CLUSTER_NAME_NIGHTLY
    gcloud --quiet config set compute/zone ${CLOUDSDK_COMPUTE_ZONE}
}

function create_nightly_cluster {
    gcloud container --project $PROJECT_NAME clusters create $CLUSTER_NAME_NIGHTLY --zone $CLOUDSDK_COMPUTE_ZONE --username "admin" --cluster-version "1.11.8-gke.6" --machine-type "n1-standard-16" --image-type "UBUNTU" --disk-type "pd-standard" --disk-size "100" --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --num-nodes "1" --enable-cloud-logging --enable-cloud-monitoring --no-enable-ip-alias --network "projects/sai-research/global/networks/default" --subnetwork "projects/sai-research/regions/$CLOUDSDK_REGION/subnetworks/default" --addons HorizontalPodAutoscaling,HttpLoadBalancing --no-enable-autoupgrade --no-enable-autorepair
    gcloud container clusters get-credentials $CLUSTER_NAME_NIGHTLY --zone $CLOUDSDK_COMPUTE_ZONE --project $PROJECT_NAME
    kubectl config view
}

function delete_nightly_cluster {
    clusters=$(gcloud container clusters list --zone $CLOUDSDK_COMPUTE_ZONE --project $PROJECT_NAME)
    if echo "$clusters" | grep $CLUSTER_NAME_NIGHTLY; then 
        echo "Start deleting nightly cluster"
        gcloud container clusters delete $CLUSTER_NAME_NIGHTLY --zone $CLOUDSDK_COMPUTE_ZONE --project $PROJECT_NAME --quiet
        echo "Finished deleting nigtly cluster"
    else 
        echo "No nightly cluster available"
    fi
}

function install_yq {
    sudo add-apt-repository ppa:rmescandon/yq -y
    sudo apt update
    sudo apt install yq -y
}

function install_sed {
    sudo apt install --reinstall sed
}

function setup_knative {    
    cd ./install/scripts/
    ./setupKnative.sh $CLUSTER_NAME_NIGHTLY ${CLOUDSDK_COMPUTE_ZONE}
    cd ../..
}
function uninstall_keptn {
    cd ./install/scripts
    ./uninstallKeptn.sh
    cd ../..
}

function setup_knative_pr {    
    cd ./install/scripts/
    CLUSTER_IPV4_CIDR=$(gcloud container clusters describe ${CLUSTER_PR_STATUSCHECK_NAME} --zone=${CLUSTER_PR_STATUSCHECK_ZONE} | yq r - clusterIpv4Cidr)
    SERVICES_IPV4_CIDR=$(gcloud container clusters describe ${CLUSTER_PR_STATUSCHECK_NAME} --zone=${CLUSTER_PR_STATUSCHECK_ZONE} | yq r - servicesIpv4Cidr)
    ./setupKnative.sh $CLUSTER_IPV4_CIDR $SERVICES_IPV4_CIDR
    cd ../..
}

function setup_keptn_pr {    
    cd ./install/scripts/
    ./setupKeptn.sh
    cd ../..
}

function export_names {
    export EVENT_BROKER_NAME=$(kubectl describe ksvc event-broker -n keptn | grep -m 1 "Name:" | sed 's~Name:[ \t]*~~')
    ./test/assertEquals.sh $EVENT_BROKER_NAME event-broker
    
    export AUTHENTICATOR_NAME=$(kubectl describe ksvc authenticator -n keptn | grep -m 1 "Name:" | sed 's~Name:[ \t]*~~')
    ./test/assertEquals.sh $AUTHENTICATOR_NAME authenticator

    export CONTROL_NAME=$(kubectl describe ksvc control -n keptn | grep -m 1 "Name:" | sed 's~Name:[ \t]*~~')
    ./test/assertEquals.sh $CONTROL_NAME control
}

function execute_core_component_tests {
    # execute unit tests for core components
    
    # Control
    cd ./core/control
    npm install
    npm run test || exit 1
    
    # Auth
    cd ../auth
    npm install
    npm run test || exit 1
    
    # Event Broker
    cd ../eventbroker
    npm install
    npm run test || exit 1

    # Event Broker (ext)
    cd ../eventbroker-ext
    npm install
    npm run test || exit 1
    
    cd ../..
}

function execute_cli_tests {

    cd cli

    dep ensure

    ENDPOINT="$(kubectl get ksvc control -n keptn -o=yaml | yq r - status.domain)"
    while [ "$ENDPOINT" = "null" ]; do sleep 30; ENDPOINT="$(kubectl get ksvc control -n keptn -o=yaml | yq r - status.domain)"; echo "waiting for control service"; done
    printf "https://" > ~/.keptnmock
    kubectl get ksvc control -n keptn -o=yaml  | yq r - status.domain >> ~/.keptnmock

    AUTH_ENDPOINT="$(kubectl get ksvc authenticator -n keptn -o=yaml | yq r - status.domain)"
    while [ "$AUTH_ENDPOINT" = "null" ]; do sleep 30; AUTH_ENDPOINT="$(kubectl get ksvc authenticator -n keptn -o=yaml | yq r - status.domain)"; echo "waiting for authenticator service"; done

    set +x
    SEC="$(kubectl get secret keptn-api-token  -n keptn -o=yaml | yq r - data.keptn-api-token | base64 --decode)"
    echo "${SEC}" >> ~/.keptnmock
    set -x

    # execute GO tests
    go test ${gobuild_args} -timeout 240s ./... || exit 1
    cd ..
}

function build_and_install_cli {
    # Build CLI for end-to-end test
    cd cli/
    dep ensure
    go build -o keptn
    mv keptn /usr/local/bin/keptn
    cd ..
}

function install_hub {
    # Install hub
    sudo wget https://github.com/github/hub/releases/download/v2.6.0/hub-linux-amd64-2.6.0.tgz
    tar -xzf hub-linux-amd64-2.6.0.tgz
    sudo cp hub-linux-amd64-2.6.0/bin/hub /bin/
}
