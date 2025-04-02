## Refund Protocol

A protocol for handling refunds and chargebacks in a non-custodial manner. This protocol introduces an arbiter system that can mediate disputes between payment senders and receivers, providing a better user experience to stablecoin payments while still allowing receivers to retain control over their funds.

## Setup

### Prerequisites

1. Install Foundry:
```shell
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

2. Initialize submodules:
```shell
git submodule update --init --recursive
```

## Development

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
