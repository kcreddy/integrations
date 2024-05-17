# Gigamon Integration

The [AWS Bedrock](https://docs.aws.amazon.com/bedrock/index.html) model
invocation logs integration allows you to easily connect your Bedrock model
invocation logging to Elastic for seamless collection of invocation logs to
monitor usage. Elastic Security can leverage this data for security analytics
including correlation, visualization and incident response. With invocation
logging, you can collect the full request and response data, and any metadata
associated with use of your account.

## Compatibility

## Data streams

The Gigamon integration currently provides a single
data stream: `ami`.

## Requirements

- Elastic Agent must be installed.
- You can install only one Elastic Agent per host.

### Installing and managing an Elastic Agent:

You have a few options for installing and managing an Elastic Agent:

### Install a Fleet-managed Elastic Agent (recommended):

With this approach, you install Elastic Agent and use Fleet in Kibana to
define, configure, and manage your agents in a central location. We recommend
using Fleet management because it makes the management and upgrade of your
agents considerably easier.

### Install Elastic Agent in standalone mode (advanced users):

With this approach, you install Elastic Agent and manually configure the agent
locally on the system where it is installed. You are responsible for managing
and upgrading the agents. This approach is reserved for advanced users only.

### Install Elastic Agent in a containerized environment:

You can run Elastic Agent inside a container, either with Fleet Server or
standalone. Docker images for all versions of Elastic Agent are available
from the Elastic Docker registry, and we provide deployment manifests for
running on Kubernetes.

There are some minimum requirements for running Elastic Agent and for more
information, refer to the link [here](https://www.elastic.co/guide/en/fleet/current/elastic-agent-installation.html).

The minimum **kibana.version** required is **8.12.0**.


### Setup

## Gigamon setup


{{fields "ami"}}

{{event "ami"}}