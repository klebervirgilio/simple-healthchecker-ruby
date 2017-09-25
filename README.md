# Simple Ruby Heathchecher

This project was created to show how a Rubyist can get up to speed with Go.

### Simulates a scenario where services are down

```sh
# run healthcheck serial
$ make failed-scenario
# run healthcheck in parallel
$ make parallel-failed-scenario
```

### Simulates a scenario where all services are up and running

```sh
# run healthcheck serial
$ make success-scenario
# run healthcheck in parallel
$ make parallel-success-scenario
```
