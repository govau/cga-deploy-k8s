# Deployment config and scripts for deploying kubernetes in cloud.gov.au

## Debugging a container that wont start

It may be necessary to ssh into a worker node. We use AWS SSM Sessions Manager installed on each node using a Daemonset - using <https://github.com/govau/kube-ssm-agent>.

_You will first need to [install the session manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)._

```bash
export AWS_PROFILE=k-cld # Set this to the environment you are debugging

NAMESPACE=kube-ssm-agent

# Attach the required policy to our worker nodes to use AWS SessionManager
aws iam attach-role-policy --role-name eks-worker-node --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM

kubectl create namespace ${NAMESPACE}

kubectl apply -n ${NAMESPACE} -f <(cat <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ssm-agent
  labels:
    k8s-app: ssm-agent
spec:
  selector:
    matchLabels:
      name: ssm-agent
  template:
    metadata:
      labels:
        name: ssm-agent
    spec:
      hostNetwork: true
      containers:
      - image: govau/kube-ssm-agent:latest
        name: ssm-agent
        securityContext:
          runAsUser: 0
          privileged: true
        volumeMounts:
        # Allows systemctl to communicate with the systemd running on the host
        - name: dbus
          mountPath: /var/run/dbus
        - name: run-systemd
          mountPath: /run/systemd
        # Allows to peek into systemd units that are baked into the official EKS AMI
        - name: etc-systemd
          mountPath: /etc/systemd
        # This is needed in order to fetch logs NOT managed by journald
        # journallog is stored only in memory by default, so we need
        #
        # If all you need is access to persistent journals, /var/log/journal/* would be enough
        # FYI, the volatile log store /var/run/journal was empty on my nodes. Perhaps it isn't used in Amazon Linux 2 / EKS AMI?
        # See https://askubuntu.com/a/1082910 for more background
        - name: var-log
          mountPath: /var/log
        - name: var-run
          mountPath: /var/run
        - name: run
          mountPath: /run
        - name: usr-lib-systemd
          mountPath: /usr/lib/systemd
        - name: etc-machine-id
          mountPath: /etc/machine-id
        - name: etc-sudoers
          mountPath: /etc/sudoers.d
        - name: var-lib-docker-containers
          mountPath: /var/lib/docker/containers
      volumes:
      # for systemctl to systemd access
      - name: dbus
        hostPath:
          path: /var/run/dbus
          type: Directory
      - name: run-systemd
        hostPath:
          path: /run/systemd
          type: Directory
      - name: etc-systemd
        hostPath:
          path: /etc/systemd
          type: Directory
      - name: var-log
        hostPath:
          path: /var/log
          type: Directory
      # mainly for dockerd access via /var/run/docker.sock
      - name: var-run
        hostPath:
          path: /var/run
          type: Directory
      # var-run implies you also need this, because
      # /var/run is a synmlink to /run
      # sh-4.2$ ls -lah /var/run
      # lrwxrwxrwx 1 root root 6 Nov 14 07:22 /var/run -> ../run
      - name: run
        hostPath:
          path: /run
          type: Directory
      - name: usr-lib-systemd
        hostPath:
          path: /usr/lib/systemd
          type: Directory
      # Required by journalctl to locate the current boot.
      # If omitted, journalctl is unable to locate host's current boot journal
      - name: etc-machine-id
        hostPath:
          path: /etc/machine-id
          type: File
      # Avoid this error > ERROR [MessageGatewayService] Failed to add ssm-user to sudoers file: open /etc/sudoers.d/ssm-agent-users: no such file or directory
      - name: etc-sudoers
        hostPath:
          path: /etc/sudoers.d
          type: Directory
      # For accessing log files
      - name: var-lib-docker-containers
        hostPath:
          path: /var/lib/docker/containers
          type: Directory
EOF
)

# Wait for the pods to start
kubectl -n $NAMESPACE get all

# See the instances connect to ssm
aws ssm describe-instance-information

# You can now ssh to a worker node instance
aws ssm start-session --target i-1234....

# See which worker node a pod is running on
kubectl get pods -o wide
```
