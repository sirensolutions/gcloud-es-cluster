Google Cloud elasticsearch cluster
===================================

Sign up for google compute cloud. This requires a credit card number for antispam, even if it's not (yet) being charged.

In the settings, set the default zone to be europe-west1-b. This uses Xeon v5 (sandy bridge) 2.5GHz machines by default.

Then go to the metadata section and add some project-level ssh keys. These:

- MUST NOT contain any embedded newlines
- MUST be of the format "ssh-XXX XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX user@domain.com"

The email address is parsed to automatically populate user accounts matching the private keys. Changes are live-propagated to all instances, even running ones.

Create a new f1-micro instance of ubuntu-2004-lts, called es-controller. This will be a persistent machine that enables us to perform further tasks programmatically. The advantage of doing it this way is that key-based access to the API is relatively painless, and also network proximity to the slaves. Using the micro instance ensures that we can leave it running at minimal cost. This server should not therefore be used for any heavy lifting - spin up a slave instance for that.
Make sure that the disk is set to *not* be deleted on instance deletion. While we never intend to delete this instance, we can't rule out accidents.

In order for the API keys to be available inside the VM, we need to add it to the "allow full access" cloud API access scope. This must be done while the VM is shut down.

Now turn on the VM and connect using your SSH key - the username will be the user part of the email address in the ssh key. *BE SURE TO FORWARD YOUR SSH AGENT*

Since es-controller will get an ephemeral IP address and will have to download code from the artifactory, it *must* be attached to the VPN. Do this now (and configure any other necessary access controls).

Run (as yourself!) `gcloud init --console-only`. Select the default account, and the default project. This may fail, but it doesn't seem to be a problem...

Now set some defaults:

```
gcloud config set compute/region europe-west1
gcloud config set compute/zone europe-west1-b
```

The default zone can be overridden by setting an envar, e.g.:

```
export CLOUDSDK_COMPUTE_ZONE=europe-west1-c
```

To create a machine, invoke e.g. the following:

```
gcloud compute instances create es-node1 --image-family=ubuntu-2004-lts --image-project=ubuntu-os-cloud --machine-type=n1-highmem-2
```

Note that you must specify both --image-family *and* --image-project. This will produce output of the form:

```
Created [https://www.googleapis.com/compute/v1/projects/lustrous-bit-174314/zones/europe-west1-b/instances/es-node1].
NAME      ZONE            MACHINE_TYPE  PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP  STATUS
es-node1  europe-west1-b  n1-highmem-4               10.132.0.3                RUNNING
```

You can list all machines in a similar format by incanting `gcloud compute instances list` and get details with `gcloud compute instances describe <instance>`.
To delete, run `gcloud compute instances delete <instance>` - this requires a confirmation unless you supply `-q`.


Constructors
------------

To call a script at instance creation we store it on the controller node and then reference it when we create new slaves.
This is known by Google as a "startup" script, which is a misnomer as it only gets run on the *initial* startup of the slave.
In this project we will call it the "*puller*" script, as its sole function is to `git pull` the constructor from github and
invoke it with the appropriate arguments. Most of the logic is then contained in the constructor.

- The spawner script is `spawner.sh`. This runs on the controller, creates a one-shot puller script and invokes gcloud to create the slaves.
- The constructor script is `constructor.sh`. This is invoked on each slave node by the puller.

There are also two other scripts for use on the controller:

- `killer.sh` deletes all nodes in a given cluster. It assumes the node naming convention used in the spawner.
- `status.sh` lists all running clusters. With the argument "-v" it also queries elasticsearch for the status of the cluster; with the option "-n" it queries the cluster nodes state.


Proxy
-----

To allow slaves to download stuff without having a routable IP, we install squid on the controller and add the following to /etc/squid/squid.conf:

```
acl localnet src 10.0.0.0/8
http_access allow localnet
```

This will allow the slaves access to both public and private websites (e.g. artifactory) by setting the envar http_proxy="http://<controller_ip>:3128/".
