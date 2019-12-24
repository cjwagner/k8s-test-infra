#! /bin/bash -e
# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# The presubmit jobs for the different Kubernetes-CSI repos are all
# the same except for the repo name. As Prow has no way of specifying
# the same job for multiple repos and manually copy-and-paste would be
# tedious, this script is used instead to generate them.

base="$(dirname $0)"

# The latest stable Kubernetes version for testing alpha repos
latest_stable_k8s_version="1.17.0"
latest_stable_k8s_minor_version="1.17"

# We need this image because it has Docker in Docker and go.
dind_image="gcr.io/k8s-testimages/kubekins-e2e:v20191221-fe232fc-master"

# All kubernetes-csi repos which are part of the hostpath driver example.
# For these repos we generate the full test matrix. For each entry here
# we need a "sig-storage-<repo>" dashboard in
# config/testgrids/kubernetes/sig-storage/config.yaml.
hostpath_example_repos="
csi-driver-host-path
external-attacher
external-provisioner
external-resizer
external-snapshotter
livenessprobe
node-driver-registrar
"

# kubernetes-csi repos which only need to be tested against at most a
# single Kubernetes version. We generate unit, stable and alpha jobs
# for these, without specifying a Kubernetes version. What the repo
# then tests in those jobs is entirely up to the repo.
#
# This list is currently empty, but such a job might be useful again
# in the future, so the code generator code below is kept.
single_kubernetes_repos="
"

# kubernetes-csi repos which only need unit testing.
unit_testing_repos="
csi-test
csi-release-tools
csi-lib-utils
csi-driver-flex
csi-proxy
"

# No Prow support in them yet.
# csi-driver-fibre-channel
# csi-driver-image-populator
# csi-driver-iscsi
# csi-driver-nfs
# csi-lib-fc
# csi-lib-iscsi

# All branches that do *not* support Prow testing. All new branches
# are expected to have that support, therefore these list should be
# fixed. By blacklisting old branches we can avoid Prow config
# changes each time a new branch gets created.
skip_branches_cluster_driver_registrar='^(release-1.0)$'
skip_branches_csi_lib_utils='^(release-0.1|release-0.2)$'
skip_branches_csi_test='^(release-0.3|release-1.0|v0.1.0|v0.2.0)$'
skip_branches_external_attacher='^(release-0.2.0|release-0.3.0|release-0.4|release-1.0|v0.1.0)$'
skip_branches_external_provisioner='^(release-0.2.0|release-0.3.0|release-0.4|release-1.0|v0.1.0)$'
skip_branches_external_snapshotter='^(k8s_1.12.0-beta.1|release-0.4|release-1.0)$'
skip_branches_livenessprobe='^(release-0.4|release-1.0)$'
skip_branches_node_driver_registrar='^(release-1.0)$'

skip_branches () {
    eval echo \\\"\$skip_branches_$(echo $1 | tr - _)\\\" | grep -v '""'
}

find "$base" -name '*.yaml' -exec grep -q 'generated by gen-jobs.sh' '{}' \; -delete

# Resource usage of a job depends on whether it needs to build Kubernetes or not.
resources_for_kubernetes () {
    local kubernetes="$1"

    case $kubernetes in master) cat <<EOF
      resources:
        requests:
          # these are both a bit below peak usage during build
          # this is mostly for building kubernetes
          memory: "9000Mi"
          # during the tests more like 3-20m is used
          cpu: 2000m
EOF
                            ;;
                            *) cat <<EOF
        resources:
          requests:
            cpu: 2000m
EOF
                            ;;
    esac
}

# Combines deployment and Kubernetes version in a job suffix like "1-14-on-kubernetes-1-13".
kubernetes_job_name () {
    local deployment="$1"
    local kubernetes="$2"
    echo "$(echo "$deployment" | tr . -)-on-kubernetes-$(echo "$kubernetes" | tr . - | sed 's/\([0-9]*\)-\([0-9]*\)-\([0-9]*\)/\1-\2/')"
}

# Combines type ("ci" or "pull"), repo, test type ("unit", "alpha", "non-alpha") and deployment+kubernetes into a
# Prow job name of the format <type>-kubernetes-csi[-<repo>][-<test type>][-<kubernetes job name].
# The <test type> part is only added for "unit" and "non-alpha" because there is no good name for it ("stable"?!)
# and to keep the job name a bit shorter.
job_name () {
    local type="$1"
    local repo="$2"
    local tests="$3"
    local deployment="$4"
    local kubernetes="$5"
    local name

    name="$type-kubernetes-csi"
    if [ "$repo" ]; then
        name+="-$repo"
    fi
    name+=$(test_name "$tests" "$deployment" "$kubernetes")
    echo "$name"
}

# Given a X.Y.Z version string, returns the minor version.
get_minor_version() {
    local ver="$1"
    local minor="$ver"

    if [ "$ver" != "master" ]; then
      ver="$(echo "${ver}" | sed -e 's/\([0-9]*\)\.\([0-9]*\).*/\1\.\2/')"
    fi
    echo "$ver"
}

# Generates the testgrid annotations. "ci" jobs all land in the same
# "sig-storage-csi-ci" and send alert emails, "pull" jobs land in "sig-storage-csi-<repo>"
# and don't alert. Some repos only have a single pull job. Those
# land in "sig-storage-csi-other".
annotations () {
    local indent="$1"
    shift
    local type="$1"
    local repo="$2"
    local tests="$3"
    local deployment="$4"
    local kubernetes="$5"
    local description

    kubernetes="$(get_minor_version "$kubernetes")"

    echo "annotations:"
    case "$type" in
        ci)
            echo "${indent}testgrid-dashboards: sig-storage-csi-ci"
            local alpha_testgrid_prefix="$(if [ "$tests" = "alpha" ]; then echo alpha-; fi)"
            echo "${indent}testgrid-tab-name: ${alpha_testgrid_prefix}${deployment}-on-${kubernetes}"
            echo "${indent}testgrid-alert-email: kubernetes-sig-storage-test-failures@googlegroups.com"
            description="periodic Kubernetes-CSI job"
            ;;
        pull)
            local testgrid
            local name=$(test_name "$tests" "$deployment" "$kubernetes" | sed -e 's/^-//')
            if [ "$name" ]; then
                testgrid="sig-storage-csi-$repo"
            else
                testgrid="sig-storage-csi-other"
                name=$(job_name "$@")
            fi
            echo "${indent}testgrid-dashboards: $testgrid"
            echo "${indent}testgrid-tab-name: $name"
            description="Kubernetes-CSI pull job"
            ;;
    esac

    if [ "$repo" ]; then
        description+=" in repo $repo"
    fi
    if [ "$tests" ]; then
        description+=" for $tests tests"
    fi
    if [ "$deployment" ] || [ "$kubernetes" ]; then
        description+=", using deployment $deployment on Kubernetes $kubernetes"
    fi
    echo "${indent}description: $description"
}

# Common suffix for job names which contains informatiopn about the test and cluster.
# Empty or starts with a hyphen.
test_name() {
    local tests="$1"
    local deployment="$2"
    local kubernetes="$3"
    local name

    if [ "$tests" ] && [ "$tests" != "non-alpha" ]; then
        name+="-$tests"
    fi
    if [ "$deployment" ] || [ "$kubernetes" ]; then
        name+="-$(kubernetes_job_name "$deployment" "$kubernetes")"
    fi
    echo "$name"
}

# "alpha" and "non-alpha" need to be expanded to different CSI_PROW_TESTS names.
expand_tests () {
    case "$1" in
        non-alpha)
            echo "sanity serial parallel";;
        alpha)
            echo "serial-alpha parallel-alpha";;
        *)
            echo "$1";;
    esac
}

# "alpha" features can be breaking across releases and
# therefore cannot be a required job
pull_optional() {
    local tests="$1"
    local kubernetes="$2"

    if [ "$tests" == "alpha" ]; then
        echo "true"
    elif [ "$kubernetes" == "1.18.0" ]; then
        # Testing 1.18 may require updates to release-tools.
        # Once that is done, and tests are passing,
        # this can be set to the next k8s version
        echo "true"
    else
        echo "false"
    fi
}

pull_alwaysrun() {
    if [ "$1" != "alpha" ]; then
        echo "true"
    else
        echo "false"
    fi
}

for repo in $hostpath_example_repos; do
    mkdir -p "$base/$repo"
    cat >"$base/$repo/$repo-config.yaml" <<EOF
# generated by gen-jobs.sh, do not edit manually

presubmits:
  kubernetes-csi/$repo:
EOF

    for tests in non-alpha alpha; do
        for deployment in 1.15 1.16 1.17; do # must have a deploy/kubernetes-<version> dir in csi-driver-host-path
            for kubernetes in 1.15.3 1.16.2 1.17.0; do # these versions must have pre-built kind images (see https://hub.docker.com/r/kindest/node/tags)
                # We could generate these pre-submit jobs for all combinations, but to save resources in the Prow
                # cluster we only do it for those cases where the deployment matches the Kubernetes version.
                # Once we have more than two supported Kubernetes releases we should limit this to the most
                # recent two.
                #
                # Periodic jobs need to test the full matrix.
                if echo "$kubernetes" | grep -q "^$deployment"; then
                    # Alpha jobs only run on the latest version
                    if [ "$tests" != "alpha" ] || [ "$kubernetes" == "$latest_stable_k8s_version" ]; then
                        # These required jobs test the binary built from the PR against
                        # older, stable hostpath driver deployments and Kubernetes versions
                        cat >>"$base/$repo/$repo-config.yaml" <<EOF
  - name: $(job_name "pull" "$repo" "$tests" "$deployment" "$kubernetes")
    always_run: $(pull_alwaysrun "$tests")
    optional: $(pull_optional "$tests" "$kubernetes")
    decorate: true
    skip_report: false
    skip_branches: [$(skip_branches $repo)]
    labels:
      preset-service-account: "true"
      preset-dind-enabled: "true"
      preset-kind-volume-mounts: "true"
    $(annotations "      " "pull" "$repo" "$tests" "$deployment" "$kubernetes")
    spec:
      containers:
      # We need this image because it has Docker in Docker and go.
      - image: ${dind_image}
        command:
        - runner.sh
        args:
        - ./.prow.sh
        env:
        # We pick some version for which there are pre-built images for kind.
        # Update only when the newer version is known to not cause issues,
        # otherwise presubmit jobs may start to fail for reasons that are
        # unrelated to the PR. Testing against the latest Kubernetes is covered
        # by periodic jobs (see https://k8s-testgrid.appspot.com/sig-storage-csi-ci#Summary).
        - name: CSI_PROW_KUBERNETES_VERSION
          value: "$kubernetes"
        - name: CSI_PROW_KUBERNETES_DEPLOYMENT
          value: "$deployment"
        - name: CSI_PROW_TESTS
          value: "$(expand_tests "$tests")"
        # docker-in-docker needs privileged mode
        securityContext:
          privileged: true
$(resources_for_kubernetes "$kubernetes")
EOF
                    fi
                fi
            done # end kubernetes


            # These optional jobs test the binary built from the PR against
            # older, stable hostpath driver deployments and Kubernetes master
            if [ "$tests" != "alpha" ] || [ "$deployment" == "$latest_stable_k8s_minor_version" ]; then
                cat >>"$base/$repo/$repo-config.yaml" <<EOF
  - name: $(job_name "pull" "$repo" "$tests" "$deployment" master)
    # Explicitly needs to be started with /test.
    # This cannot be enabled by default because there's always the risk
    # that something changes in master which breaks the pre-merge check.
    always_run: false
    optional: true
    decorate: true
    skip_report: false
    labels:
      preset-service-account: "true"
      preset-dind-enabled: "true"
      preset-bazel-remote-cache-enabled: "true"
      preset-kind-volume-mounts: "true"
    $(annotations "      " "pull" "$repo" "$tests" "$deployment" master)
    spec:
      containers:
      # We need this image because it has Docker in Docker and go.
      - image: ${dind_image}
        command:
        - runner.sh
        args:
        - ./.prow.sh
        env:
        - name: CSI_PROW_KUBERNETES_VERSION
          value: "latest"
        - name: CSI_PROW_TESTS
          value: "$(expand_tests "$tests")"
        # docker-in-docker needs privileged mode
        securityContext:
          privileged: true
$(resources_for_kubernetes master)
EOF
            fi
        done # end deployment
    done # end tests

    cat >>"$base/$repo/$repo-config.yaml" <<EOF
  - name: $(job_name "pull" "$repo" "unit")
    always_run: true
    decorate: true
    skip_report: false
    skip_branches: [$(skip_branches $repo)]
    labels:
      preset-service-account: "true"
      preset-dind-enabled: "true"
      preset-bazel-remote-cache-enabled: "true"
      preset-kind-volume-mounts: "true"
    $(annotations "      " "pull" "$repo" "unit")
    spec:
      containers:
      # We need this image because it has Docker in Docker and go.
      - image: ${dind_image}
        command:
        - runner.sh
        args:
        - ./.prow.sh
        env:
        - name: CSI_PROW_TESTS
          value: "unit"
        # docker-in-docker needs privileged mode
        securityContext:
          privileged: true
$(resources_for_kubernetes master)
EOF
done

for repo in $single_kubernetes_repos; do
    mkdir -p "$base/$repo"
    cat >"$base/$repo/$repo-config.yaml" <<EOF
# generated by gen-jobs.sh, do not edit manually

presubmits:
  kubernetes-csi/$repo:
EOF
    for tests in non-alpha unit alpha; do
        cat >>"$base/$repo/$repo-config.yaml" <<EOF
  - name: $(job_name "pull" "$repo" "$tests")
    always_run: true
    optional: $(pull_optional "$tests")
    decorate: true
    skip_report: false
    skip_branches: [$(skip_branches $repo)]
    labels:
      preset-service-account: "true"
      preset-dind-enabled: "true"
      preset-kind-volume-mounts: "true"
    $(annotations "      " "pull" "$repo" "$tests")
    spec:
      containers:
      # We need this image because it has Docker in Docker and go.
      - image: ${dind_image}
        command:
        - runner.sh
        args:
        - ./.prow.sh
        env:
        - name: CSI_PROW_TESTS
          value: "$(expand_tests "$tests")"
        # docker-in-docker needs privileged mode
        securityContext:
          privileged: true
$(resources_for_kubernetes default)
EOF
    done
done

# Single job for everything.
for repo in $unit_testing_repos; do
    mkdir -p "$base/$repo"
    cat >"$base/$repo/$repo-config.yaml" <<EOF
# generated by gen-jobs.sh, do not edit manually

presubmits:
  kubernetes-csi/$repo:
EOF

    cat >>"$base/$repo/$repo-config.yaml" <<EOF
  - name: pull-kubernetes-csi-$repo
    always_run: true
    decorate: true
    skip_report: false
    skip_branches: [$(skip_branches $repo)]
    labels:
      preset-service-account: "true"
      preset-dind-enabled: "true"
      preset-kind-volume-mounts: "true"
    $(annotations "      " "pull" "$repo")
    spec:
      containers:
      # We need this image because it has Docker in Docker and go.
      - image: ${dind_image}
        command:
        - runner.sh
        args:
        - ./.prow.sh
        # docker-in-docker needs privileged mode
        securityContext:
          privileged: true
$(resources_for_kubernetes default)
EOF
done

# The csi-driver-host-path repo contains different deployments. We
# test those against different Kubernetes releases at regular
# intervals. We do this for several reasons:
# - Detect regressions in Kubernetes. This can happen because
#   Kubernetes does not test against all of our deployments when
#   preparing an update.
# - Not all test configurations are covered by pre-submit jobs.
# - The actual deployment content is not used verbatim in pre-submit
#   jobs. The csi-driver-host-path image itself always gets replaced.
#
# This does E2E testing, with alpha tests only enabled in cases where
# it makes sense. Unit tests are not enabled because we aren't building
# the components.
cat >>"$base/csi-driver-host-path/csi-driver-host-path-config.yaml" <<EOF

periodics:
EOF

for tests in non-alpha alpha; do
    for deployment in 1.15 1.16 1.17; do
        for kubernetes in 1.15 1.16 1.17 master; do
            if [ "$tests" = "alpha" ]; then
                # No version skew testing of alpha features, deployment has to match Kubernetes.
                if ! echo "$kubernetes" | grep -q "^$deployment"; then
                    continue
                fi
                # Alpha testing is only done on the latest stable version or
                # master
                if [ "$kubernetes" != "$latest_stable_k8s_minor_version" ] && [ "$kubernetes" != "master" ]; then
                    continue
                fi
            fi

            # Skip generating tests where the k8s version is lower than the deployment version
            # because we do not support running newer deployments and sidecars on older kubernetes releases.
            # The recommended Kubernetes version can be found in each kubernetes-csi sidecar release.
			if [[ $kubernetes < $deployment ]]; then
                continue
            fi
            actual="$(if [ "$kubernetes" = "master" ]; then echo latest; else echo "release-$kubernetes"; fi)"
            cat >>"$base/csi-driver-host-path/csi-driver-host-path-config.yaml" <<EOF
- interval: 6h
  name: $(job_name "ci" "" "$tests" "$deployment" "$kubernetes")
  decorate: true
  extra_refs:
  - org: kubernetes-csi
    repo: csi-driver-host-path
    base_ref: master
  labels:
    preset-service-account: "true"
    preset-dind-enabled: "true"
    preset-bazel-remote-cache-enabled: "$(if [ "$kubernetes" = "master" ]; then echo true; else echo false; fi)"
    preset-kind-volume-mounts: "true"
  $(annotations "    " "ci" "" "$tests" "$deployment" "$kubernetes")
  spec:
    containers:
    # We need this image because it has Docker in Docker and go.
    - image: ${dind_image}
      command:
      - runner.sh
      args:
      - ./.prow.sh
      env:
      - name: CSI_PROW_KUBERNETES_VERSION
        value: "$actual"
      - name: CSI_PROW_BUILD_JOB
        value: "false"
      - name: CSI_PROW_DEPLOYMENT
        value: "kubernetes-$deployment"
      - name: CSI_PROW_TESTS
        value: "$(expand_tests "$tests")"
      # docker-in-docker needs privileged mode
      securityContext:
        privileged: true
$(resources_for_kubernetes "$actual")
EOF
        done
    done
done

# The canary builds use the latest sidecars from master and run them on
# specific Kubernetes versions, using the default deployment for that Kubernetes
# release.
for kubernetes in 1.15.3 1.16.2 1.17.0 master; do
    actual="${kubernetes/master/latest}"

    for tests in non-alpha alpha; do
        # Alpha with latest sidecars only on master.
        if [ "$tests" = "alpha" ] && [ "$kubernetes" != "master" ]; then
            continue
        fi
        alpha_testgrid_prefix="$(if [ "$tests" = "alpha" ]; then echo alpha-; fi)"
        cat >>"$base/csi-driver-host-path/csi-driver-host-path-config.yaml" <<EOF
- interval: 6h
  name: $(job_name "ci" "" "$tests" "canary" "$(get_minor_version "$kubernetes")")
  decorate: true
  extra_refs:
  - org: kubernetes-csi
    repo: csi-driver-host-path
    base_ref: master
  labels:
    preset-service-account: "true"
    preset-dind-enabled: "true"
    preset-bazel-remote-cache-enabled: "true"
    preset-kind-volume-mounts: "true"
  $(annotations "    " "ci" "" "$tests" "canary" "$kubernetes")
  spec:
    containers:
    # We need this image because it has Docker in Docker and go.
    - image: ${dind_image}
      command:
      - runner.sh
      args:
      - ./.prow.sh
      env:
      - name: CSI_PROW_KUBERNETES_VERSION
        value: "$actual"
      - name: CSI_PROW_BUILD_JOB
        value: "false"
      # Replace images....
      - name: CSI_PROW_HOSTPATH_CANARY
        value: "canary"
      # ... but the RBAC rules only when testing on master.
      # The other jobs test against the unmodified deployment for
      # that Kubernetes version, i.e. with the original RBAC rules.
      - name: UPDATE_RBAC_RULES
        value: "$([ "$kubernetes" = "master" ] && echo "true" || echo "false")"
      - name: CSI_PROW_TESTS
        value: "$(expand_tests "$tests")"
      # docker-in-docker needs privileged mode
      securityContext:
        privileged: true
$(resources_for_kubernetes "$actual")
EOF
    done
done
