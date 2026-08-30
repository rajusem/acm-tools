# Enabling OpenShift Virtualization on an AWS SNO Cluster

How to get Red Hat OpenShift Virtualization running on a single-node OpenShift (SNO) cluster provisioned on AWS through an ACM/Hive `ClusterPool`.

Verified end-to-end on 2026-08-29 against `obsint-sno-m7i-4xlarge-5-bpnzd` (OCP 5.0.0-ec.6, CNV 4.22.0, `m7i.4xlarge`, `us-west-2a`).

---

## Quick Path

`bin/sno-virt` automates everything below. Use it for the normal case; read the rest
when something goes wrong or you need to understand why a step exists.

```bash
# 1. Where does this cluster stand?
bin/sno-virt status --cluster <cluster-ns> --hub-context <hub-ctx>

# 2. Turn on EC2 nested virtualization (stops and resumes the cluster)
bin/sno-virt enable --cluster <cluster-ns> --hub-context <hub-ctx>

# 3. Log in to the spoke, then prove KVM is usable
bin/sno-virt check-node --spoke-context current

# 4. Install the operator
bin/sno-virt install --spoke-context current

# 5. Boot a real VM to prove it end to end
bin/sno-virt smoke-test --spoke-context current
bin/sno-virt cleanup --spoke-context current
```

Pass `--cluster` to the spoke-side commands as well, and they will refuse to act if
the kubeconfig context points at a different cluster.

---

## The Core Constraint

OpenShift Virtualization runs VMs with KVM. KVM requires the CPU to expose hardware virtualization extensions (`vmx` on Intel, `svm` on AMD).

Standard EC2 instances are themselves virtual machines. Historically the Nitro hypervisor did **not** pass `vmx` through to the guest, which is why Red Hat's documented answer is "use a `.metal` instance".

Two ways to satisfy the constraint on AWS:

| | Bare metal | Nested virtualization |
|---|---|---|
| Instance types | `c5n.metal`, `m5.metal`, `m7i.metal-24xl` | `C7i`, `M7i`, `R7i`, `C7i-flex`, `M7i-flex`, `I7i`, `C8i`, `M8i`, `R8i`, `C8id`, `M8id`, `R8id`, `C8i-flex`, `M8i-flex`, `R8i-flex`, `X8i` |
| Smallest usable | ~48–96 vCPU | 4xlarge (16 vCPU) |
| Approx. cost | ~$4–5/hr | ~$0.81/hr |
| Red Hat support | Supported (GA on AWS) | **Not supported** — lab/dev only |
| Enabled by default | Yes | **No** — requires an explicit EC2 CPU option |

This guide covers the **nested virtualization** path, which is what the `obsint-sno-m7i-4xlarge-*` pools use.

> **Support status.** Red Hat's compatible-platforms list is bare-metal servers, ARM64 bare metal, and IBM Z/LinuxONE LPARs. AWS is GA *via bare-metal instances*. Nothing in Red Hat's documentation covers AWS nested virtualization. Treat this configuration as unsupported: fine for right-sizing and feature testing, not for anything that would become a support case.

---

## Requirements

From the OpenShift Virtualization documentation (OCP 4.20, "Hardware, software, and operational requirements"):

**CPU**
- AMD64 or Intel 64-bit (`x86-64-v2`)
- Intel VT-x or AMD-V enabled
- NX (no execute) flag enabled

**Operating system**
- RHCOS on worker nodes. RHEL worker nodes are not supported.

**Storage**
- A default storage class must exist. On AWS SNO, `gp3-csi` is the default and is sufficient.
- RWX + Block is optimal but only matters for live migration, which SNO does not support.
- EBS limitations: `gp2`/`gp3` do not support live migration; `io2` does.

**Resource overhead** — on SNO the single node is both infra and worker, so it pays both columns:

| Overhead | Per infra node | Per worker node | SNO total |
|---|---|---|---|
| Memory | ~150 MiB | ~360 MiB | ~510 MiB + 2179 MiB cluster-wide = **~2.6 GiB** |
| CPU | ~4 cores | ~2 cores | **~6 cores** |
| Storage | ~10 GiB | ~10 GiB | **~10 GiB** |

Per-VM memory overhead:

```
(0.002 x requested memory) + 218 MiB + 8 MiB x vCPUs + 16 MiB x graphics devices
+ 1 GiB per SR-IOV or GPU device
+ 256 MiB if SEV enabled
+ 53 MiB if TPM enabled
```

On a 16 vCPU / 64 GiB node this leaves roughly 10 vCPU and ~60 GiB for VMs. **Memory is comfortable; CPU is tight.** Expect to rely on CPU overcommit.

**SNO does not support** (per the docs): high availability, pod disruption, live migration, or VMs/templates with an eviction strategy configured.

---

## Step 1 — ClusterPool install-config

The pool's `installConfigSecretTemplateRef` secret must contain a valid SNO install-config.

```yaml
apiVersion: v1
metadata:
  name: 'obsint-sno-m7i-4xlarge-5'
baseDomain: llc.devcluster.openshift.com
controlPlane:
  hyperthreading: Enabled
  name: master
  replicas: 1                 # SNO
  platform:
    aws:
      rootVolume:
        iops: 2000
        size: 200             # 120 GB minimum + 10 GiB virt overhead + VM disks
        type: gp3
      type: m7i.4xlarge       # must be a nested-virt-capable family
compute:
- hyperthreading: Enabled
  name: 'worker'
  replicas: 0                 # SNO
  platform:
    aws:
      rootVolume:
        iops: 2000
        size: 100
        type: io1
      type: m5.xlarge
networking:
  networkType: OVNKubernetes  # OpenShiftSDN is REMOVED in OCP 5.0
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: us-west-2
```

Verify before claiming:

```bash
oc get secret <pool>-install-config -n obs-int-analytics \
  -o jsonpath='{.data.install-config\.yaml}' | base64 -d \
  | grep -E 'networkType|replicas|type: m|region'
```

To correct an existing template without writing credentials to disk:

```bash
oc get secret <pool>-install-config -n obs-int-analytics \
  -o jsonpath='{.data.install-config\.yaml}' | base64 -d \
  | sed 's/networkType: OpenShiftSDN/networkType: OVNKubernetes/' \
  | oc set data secret/<pool>-install-config \
      -n obs-int-analytics --from-file=install-config.yaml=/dev/stdin
```

A `ClusterDeployment` already created from a broken template keeps its own copy in the cluster namespace (`<cluster>-install-config`). Patch that too, or delete the `ClusterDeployment` and let the pool rebuild it.

Also confirm the pool points at working AWS credentials:

```bash
oc get clusterpool <pool> -n obs-int-analytics \
  -o jsonpath='{.spec.platform.aws.credentialsSecretRef.name}{"\n"}'
```

---

## Step 2 — Enable nested virtualization on the node

Hive has no field for this. Neither `install-config.yaml` nor `AWSMachineProviderConfig` exposes it — `AWSMachineProviderConfig.CPUOptions` contains only `ConfidentialCompute`. It must be set directly on the EC2 instance after installation.

**Prerequisites**

- AWS CLI **2.36.0 or newer**. Older versions lack `--nested-virtualization` and make `--core-count` / `--threads-per-core` mandatory.
  ```bash
  aws --version                    # need >= 2.36
  brew upgrade awscli              # macOS
  ```
- An IAM principal with **`ec2:ModifyInstanceCpuOptions`**. This is not part of the standard install permissions and usually has to be requested:
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "ec2:ModifyInstanceCpuOptions",
        "Resource": "arn:aws:ec2:us-west-2:<account-id>:instance/*"
      }
    ]
  }
  ```

**Optional: create a local AWS profile from the cluster's own credentials**

```bash
NS=<cluster-namespace>
aws configure set aws_access_key_id \
  "$(oc get secret ${NS}-aws-creds -n $NS -o jsonpath='{.data.aws_access_key_id}' | base64 -d)" \
  --profile redhat
aws configure set aws_secret_access_key \
  "$(oc get secret ${NS}-aws-creds -n $NS -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)" \
  --profile redhat
aws configure set region us-west-2 --profile redhat
aws sts get-caller-identity --profile redhat
```

**Procedure**

The instance must be stopped. Use Hive's power state rather than `aws ec2 stop-instances` so Hive stays authoritative over the node's lifecycle.

```bash
NS=<cluster-namespace>
INFRA_ID=$(oc get clusterdeployment $NS -n $NS -o jsonpath='{.spec.clusterMetadata.infraID}')

# 1. Find the instance
ID=$(aws ec2 describe-instances --profile redhat --region us-west-2 \
  --filters "Name=tag:Name,Values=${INFRA_ID}-master-0" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

# 2. Stop the cluster (this is downtime)
oc patch clusterdeployment $NS -n $NS --type=merge \
  -p '{"spec":{"powerState":"Hibernating"}}'

# 3. Wait for Hibernating
oc get clusterdeployment $NS -n $NS -o jsonpath='{.status.powerState}{"\n"}'
aws ec2 describe-instances --profile redhat --region us-west-2 --instance-ids $ID \
  --query 'Reservations[].Instances[].State.Name' --output text     # want: stopped

# 4. Enable nested virtualization
aws ec2 modify-instance-cpu-options --profile redhat --region us-west-2 \
  --instance-id $ID --nested-virtualization enabled

# 5. Resume
oc patch clusterdeployment $NS -n $NS --type=merge \
  -p '{"spec":{"powerState":"Running"}}'
```

Confirm at the AWS layer:

```bash
aws ec2 describe-instances --profile redhat --region us-west-2 --instance-ids $ID \
  --query 'Reservations[].Instances[].CpuOptions' --output json
# CoreCount: 8, ThreadsPerCore: 2, NestedVirtualization: "enabled"
```

Then confirm at the node layer (log in to the spoke):

```bash
NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
oc debug node/$NODE --quiet -- chroot /host sh -c \
  'echo "vmx: $(grep -o -m1 vmx /proc/cpuinfo || echo MISSING)"; ls -l /dev/kvm; lsmod | grep ^kvm'
```

Expected:

```
vmx: vmx
crw-rw-rw-. 1 root kvm 10, 232 /dev/kvm
kvm_intel   520192  0
kvm        1400832  1 kvm_intel
```

`kvm_intel` loads automatically on boot once the CPU exposes `vmx`. If `/dev/kvm` is missing, stop here — installing the operator will not help.

---

## Step 3 — Install OpenShift Virtualization

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: "stable"
EOF
```

Wait for the CSV, then deploy the operand:

```bash
oc get csv -n openshift-cnv        # want PHASE=Succeeded

cat <<'EOF' | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
EOF
```

The `openshift-cnv` namespace is mandatory — installing elsewhere fails.

Check the available version first if the cluster is on a pre-release OCP build:

```bash
oc get packagemanifest kubevirt-hyperconverged -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name} -> {.currentCSV}{"\n"}{end}'
```

CNV 4.22.0 installs and runs correctly on OCP 5.0.0-ec.6 even though the versions do not match. Red Hat documents that OpenShift Virtualization is only supported with its corresponding OCP version, so this is another reason the configuration is lab-only.

---

## Step 4 — Verification

```bash
# HyperConverged healthy
oc get hco kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
# want: ReconcileComplete=True Available=True Progressing=False Degraded=False Upgradeable=True

# KubeVirt deployed
oc get kubevirt -n openshift-cnv

# THE decisive check: node advertises KVM as a schedulable device
oc get node -o jsonpath='{.items[0].status.allocatable.devices\.kubevirt\.io/kvm}{"\n"}'
# want: 1k

# Default storage class present
oc get storageclass
```

`devices.kubevirt.io/kvm: 1k` is the real proof. `virt-handler` advertises it only after successfully opening `/dev/kvm`.

During initial rollout the HCO reports `Degraded=True` with `SSPDegraded: Required CRDs are missing: virtualmachines.kubevirt.io, datasources.cdi.kubevirt.io, dataimportcrons.cdi.kubevirt.io`. This is a startup ordering artifact and clears on its own within a few minutes.

---

## Step 5 — VM smoke test

```bash
oc create ns virt-smoke-test

cat <<'EOF' | oc apply -n virt-smoke-test -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: rhel9-smoke
spec:
  runStrategy: Always
  instancetype:
    kind: virtualmachineclusterinstancetype
    name: u1.medium          # 1 vCPU, 4Gi
  preference:
    kind: virtualmachineclusterpreference
    name: rhel.9
  dataVolumeTemplates:
  - metadata:
      name: rhel9-smoke-root
    spec:
      sourceRef:
        kind: DataSource
        name: rhel9
        namespace: openshift-virtualization-os-images
      storage:
        resources:
          requests:
            storage: 30Gi
  template:
    spec:
      evictionStrategy: None   # REQUIRED on SNO
      domain:
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: rhel9-smoke-root
EOF

oc get vm,vmi,dv -n virt-smoke-test -w
```

Success looks like:

```
NAME          AGE   STATUS    READY
rhel9-smoke   19h   Running   True

NAME          AGE   PHASE     IP            READY
rhel9-smoke   12m   Running   10.128.0.19   True

NAME               PHASE       PROGRESS
rhel9-smoke-root   Succeeded   100.0%
```

Clean up when finished — the VM consumes CPU and memory continuously:

```bash
oc delete ns virt-smoke-test
```

`evictionStrategy: None` is mandatory because SNO storage is RWO and there is no second node to migrate to. Without it the VM will not schedule.

---

## Troubleshooting

### `networkType OpenShiftSDN is not supported, please use OVNKubernetes`

```
level=error msg="failed to fetch Master Machines: failed to load asset \"Install Config\":
failed to create install config: invalid \"install-config.yaml\" file:
networking.networkType: Invalid value: \"OpenShiftSDN\""
```

OpenShiftSDN was removed in OCP 5.0. The provision fails in ~4 seconds at `openshift-install create manifests` and never reaches AWS, so no resources are orphaned.

Fix both the pool template and the `ClusterDeployment`'s own copy (see Step 1).

### `AuthFailure: AWS was not able to validate the provided access credentials`

```
operation error EC2: DescribeInstanceTypes, StatusCode: 401
api error AuthFailure
```

The pool's `credentialsSecretRef` points at an invalid, expired, or mistyped key. Compare against a pool that has provisioned successfully:

```bash
for p in <pool-a> <pool-b>; do
  printf '%-28s ' "$p"
  oc get secret ${p}-aws-creds -n obs-int-analytics \
    -o jsonpath='created={.metadata.creationTimestamp}{"\n"}'
done
```

Either repoint the pool at a known-good secret, or have the key replaced. Note this failure also occurs at `create manifests`, before any AWS resources are created.

### `UnauthorizedOperation ... ec2:ModifyInstanceCpuOptions`

The IAM principal lacks the permission. `--dry-run` fails identically, which confirms it is a policy gap rather than a state problem. See the policy in Step 2.

### `Unknown options: --nested-virtualization`

AWS CLI is older than 2.36. Upgrade it.

### Provision retry loop

```bash
NS=<cluster-namespace>
oc get clusterprovision -n $NS
oc logs -n $NS -l hive.openshift.io/job-type=provision -c hive --tail=150
# or, if the pod is gone:
oc get clusterprovision -n $NS -o jsonpath='{.items[0].spec.installLog}' | tail -60
```

Check `.status.installRestarts` and the `ProvisionStopped` condition to see whether Hive is still retrying.

### Cluster suddenly unreachable

Check whether something hibernated it:

```bash
oc get clusterdeployment $NS -n $NS \
  -o jsonpath='spec={.spec.powerState} status={.status.powerState}{"\n"}'
oc get clusterdeployment $NS -n $NS \
  -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.time}{"\n"}{end}'
```

A `manager=action` entry means the change came from the OpenShift/ACM web console. `hibernateAfter` on the `ClusterPool` or `ClusterDeployment` would indicate an automatic timer instead.

Hibernation is non-destructive: namespaces, VMs, DataVolumes, and the operator all survive, and `runStrategy: Always` VMs restart on resume. `NestedVirtualization` is an EC2 instance attribute and also survives.

---

## Known Limitations

**Nested virtualization is per-instance and invisible to Hive.** Every cluster claimed from a nested-virt pool needs Step 2 run against it individually. If the node is ever replaced, the setting reverts to `None` and VMs stop starting with no explanatory error at the Kubernetes layer.

**Not a supported configuration.** Red Hat supports OpenShift Virtualization on bare metal. Do not open support cases against this setup.

**SNO restrictions.** No high availability, no pod disruption budgets, no live migration, and no VMs with an eviction strategy configured.

**AWS networking restrictions.** SR-IOV and bridge CNI (including VLAN) are unavailable. Use OVN-Kubernetes secondary overlay networks for layer-2 requirements.

**Hosted control planes** for OpenShift Virtualization are not supported on AWS infrastructure.

**CPU headroom is limited.** ~6 of 16 vCPU go to virtualization overhead on SNO.

---

## Quick Reference

```bash
NS=<cluster-namespace>          # e.g. obsint-sno-m7i-4xlarge-5-bpnzd
ID=<ec2-instance-id>            # e.g. i-061955e875f88a1b5

# AWS-side state
aws ec2 describe-instances --profile redhat --region us-west-2 --instance-ids $ID \
  --query 'Reservations[].Instances[].{State:State.Name,Nested:CpuOptions.NestedVirtualization}' \
  --output table

# Hive-side state
oc get clusterdeployment $NS -n $NS \
  -o jsonpath='installed={.spec.installed} power={.status.powerState}{"\n"}'

# Node-side state (spoke)
oc get node -o jsonpath='{.items[0].status.allocatable.devices\.kubevirt\.io/kvm}{"\n"}'
oc get hco kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
```

---

## References

- [Installing — Virtualization, OCP 4.20](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/installing)
- [Use nested virtualization on EC2 — AWS](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html)
- [Nested virtualization on additional Intel platforms — AWS What's New](https://aws.amazon.com/about-aws/whats-new/2026/06/nested-virtualization-intel-us-gov-cloud/)
- [OpenShift Virtualization on AWS — Red Hat blog](https://www.redhat.com/en/blog/openshift-virtualization-on-amazon-web-services)
- [AWSMachineProviderConfig — openshift/api](https://github.com/openshift/api/blob/master/machine/v1beta1/types_awsprovider.go)
