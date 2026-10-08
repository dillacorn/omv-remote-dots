## Access
Open the service in a browser using its Tailscale address:

https://<service>.<your-tailnet>.ts.net

Example:
https://seerr.example-tailnet.ts.net

## Export certs
Only needed for local reverse proxy setups.

```bash
docker exec -it tailscale-<service> tailscale cert <service>.<your-tailnet>.ts.net
```

Example:
docker exec -it tailscale-seerr tailscale cert seerr.example-tailnet.ts.net

## Existing Jellyseerr upgrades

An in-place migration may use the machine name `seerr` but still run the
container `tailscale-jellyseerr` and store certificates under
`/docker/jellyseerr/ts/state/certs`. Keep the corresponding live Nginx
backend and certificate mount unchanged. Only change the hostname and cert
filenames when the new certificate is already available. Do not overwrite
a working migrated Pi-hole configuration with the clean-install example.
