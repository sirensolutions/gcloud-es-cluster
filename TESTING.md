gcloud-es-cluster script testing HOWTO
======================================

SSH into test-runner.siren.io. Before starting, make sure that:

* ARTIFACTORY_API_KEY, ARTIFACTORY_USERNAME and GITHUB_CREDENTIALS are defined in ~/.bashrc
* ~/.gcs-service-account.json exists and contains your API key
* Maven is configured:

```
mvn clean
cat <<'EOF' > ~/.m2/settings.xml
<settings>
  <servers>
    <server>
      <id>artifactory-releases</id>
      <!--
        Passing the Java system properties as suggested in Maven doc
        https://maven.apache.org/settings.html#Quick_Overview
      -->
      <username>${env.ARTIFACTORY_USERNAME}</username>
      <password>${env.ARTIFACTORY_API_KEY}</password>
    </server>
    <server>
      <id>artifactory-releases-local</id>
      <username>${env.ARTIFACTORY_USERNAME}</username>
      <password>${env.ARTIFACTORY_API_KEY}</password>
    </server>
    <server>
      <id>libs-release-staging-local</id>
      <username>${env.ARTIFACTORY_USERNAME}</username>
      <password>${env.ARTIFACTORY_API_KEY}</password>
    </server>
    <server>
      <id>artifactory-snapshots</id>
      <username>${env.ARTIFACTORY_USERNAME}</username>
      <password>${env.ARTIFACTORY_API_KEY}</password>
    </server>
  </servers>
  <profiles>
    <profile>
      <id>artifactory</id>
      <properties>
        <artifactory.url>https://artifactory.siren.io/artifactory</artifactory.url>
      </properties>
      <repositories>
        <repository>
          <id>artifactory-releases-local</id>
          <snapshots>
            <enabled>false</enabled>
          </snapshots>
          <name>libs-release</name>
          <url>http://artifactory.siren.io/artifactory/libs-release-local</url>
        </repository>
        <repository>
          <id>libs-release-staging-local</id>
          <snapshots>
            <enabled>false</enabled>
          </snapshots>
          <name>libs-release</name>
          <url>http://artifactory.siren.io/artifactory/libs-release-staging-local</url>
        </repository>
        <repository>
          <id>artifactory-releases</id>
          <snapshots>
            <enabled>false</enabled>
          </snapshots>
          <name>libs-release</name>
          <url>http://artifactory.siren.io/artifactory/libs-release</url>
        </repository>
        <repository>
          <id>artifactory-snapshots</id>
          <snapshots/>
          <name>libs-snapshot</name>
          <url>http://artifactory.siren.io/artifactory/libs-snapshot</url>
        </repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository>
          <id>artifactory-releases</id>
          <snapshots>
            <enabled>false</enabled>
          </snapshots>
          <name>plugins-release</name>
          <url>http://artifactory.siren.io/artifactory/plugins-release</url>
        </pluginRepository>
        <pluginRepository>
          <id>artifactory-snapshots</id>
          <snapshots/>
          <name>plugins-snapshot</name>
          <url>http://artifactory.siren.io/artifactory/plugins-snapshot</url>
        </pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>artifactory</activeProfile>
  </activeProfiles>
  <mirrors>
    <mirror>
      <id>USA</id>
      <name>USA Central</name>
      <url>https://repo1.maven.org/maven2/</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
    <mirror>
      <id>UK</id>
      <name>UK Central</name>
      <url>https://uk.maven.org/maven2</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
  </mirrors>
</settings>
EOF
```

Now build the tests and run. You will need to define GCLOUD_ES_BRANCH and DEMOS_BRANCH.

```
tmpdir=$(mktemp -d)
cd $tmpdir
git clone --recurse-submodules git@github.com:sirensolutions/gcloud-es-cluster
(cd gcloud-es-cluster && git checkout --recurse-submodules $GCLOUD_ES_BRANCH)
git clone --recurse-submodules git@github.com:sirensolutions/siren-platform
cd siren-platform
gradleOpts=(-p benchmark -is \
    -Pfederate.commit=8579c77702b13bc826e651db940b88d95bea76e5 \
    -PartifactoryApiKey="$ARTIFACTORY_API_KEY" \
    -PgithubCredentials="$GITHUB_CREDENTIALS" \
    -Pgcs.service.account.file="$HOME/.gcs-service-account.json" \
    -Duse.bundled.jdk \
    -Dpath.gcloud.es.cluster.repo="../gcloud-es-cluster" \
    -Dgit.demos.branch="$DEMOS_BRANCH")
./gradlew clean
./gradlew build --exclude-task test
./gradlew buildBundle "${gradleOpts[@]}"
./gradlew publishFederateBundle "${gradleOpts[@]}"
DEBUG=1 ./gradlew gcloudParentChildScenario1Setup "${gradleOpts[@]}"
watch gcloud compute instances list
```

Once the slaves come up, take a note of an elasticsearch node INTERNAL_IP. Now kill `watch` and try to connect to that IP on port 9200:

```
curl -Ssf http://INTERNAL_IP:9200/_cluster/state/nodes | jq .
```

To clean up, do:

```
clusterId=$(curl -Ssf http://INTERNAL_IP:9200/_cluster/state/nodes \
    |jq -r .cluster_name)
../gcloud-es-cluster/killer.sh "$clusterId"
cd
rm -rf "$tmpdir"
```
