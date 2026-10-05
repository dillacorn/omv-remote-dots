## Access
Open the service in a browser using its Tailscale address:

https://<service>.<your-tailnet>.ts.net

Example:
https://jellyseerr.example-tailnet.ts.net

## Export certs
Only needed for local reverse proxy setups.

```bash
docker exec -it tailscale-<service> tailscale cert <service>.<your-tailnet>.ts.net
```

Example:
docker exec -it tailscale-jellyseerr tailscale cert jellyseerr.example-tailnet.ts.net
