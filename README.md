Google Cloud elasticsearch cluster
===================================

Signed up for google compute cloud. This required a credit card number for antispam, but they promise (!) not to charge it until a) the free tier period runs out and b) we subsequently agree to take the paid tier.

In the settings, set the default zone to be europe-west1-b. This uses Xeon v5 (sandy bridge) 2.5GHz machines by default.

Then go to the metadata section and add some project-level ssh keys. These:

- MUST NOT contain any embedded newlines
- MUST be of the format "ssh-XXX XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX user@domain.com"

The email address is parsed to automatically populate user accounts matching the private keys. The really scary bit is that changes are live-propagated to all instances, even running ones.

Created a new f1-micro instance of ubuntu-1604-lts, called es-controller. This will be a persistent machine that enables us to perform further tasks programmatically. The advantage of doing it this way is that key-based access to the API is relatively painless, and also network proximity to the slaves. Using the micro instance ensures that we can leave it running at minimal cost. This server should not therefore be used for any heavy lifting - spin up a slave instance for that.

Since es-controller will get an ephemeral IP address and will have to download code from the artifactory, it must be attached to zerotier.

In order for the API keys to be available inside the VM, we need to add it to the "allow full access" cloud API access scope. This must be done while the VM is shut down.

Now turn on the VM and connect using your SSH key - the username will be the user part of the email address in the ssh key. *BE SURE TO FORWARD YOUR SSH AGENT*

Run (as yourself!) `gcloud init --console-only`. Select the default account, and the default project. This may fail, but it doesn't seem to be a problem...

Now set some defaults:

```
gcloud config set compute/region europe-west1
gcloud config set compute/zone europe-west1-b
```

To create a machine, invoke e.g. the following:

```
gcloud compute instances create es-node1 --image-family=ubuntu-1604-lts --image-project=ubuntu-os-cloud --machine-type=n1-highmem-2
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

To call a script at instance creation (this is the *startup* script) we store it on the controller node and then reference it on the command line.
We want to keep this as simple as possible so that we can manage changes in another file (the *constructor*). We can also store the startup script in git, but it should not be
absolutely necessary to pull the latest version down onto the controller node every time.

- The *startup* script is `pull-constructor.sh`. This is invoked on the controller node but executed on the slave. Instructions are in comments in the script itself. It should *never* change, unless we rename the github repo.
- The *constructor* script is `constructor.sh`. This contains volatile changes, and is `git pull`ed onto the slave node at runtime by the startup script.

