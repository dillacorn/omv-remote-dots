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
