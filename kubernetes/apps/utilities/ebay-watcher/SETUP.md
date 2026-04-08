# ebay-watcher — Setup Guide

## 1. Create the eBay developer app

1. Go to https://developer.ebay.com/my/keys
2. Create a **Production** app (not Sandbox)
3. Note your **App ID (Client ID)** and **Client Secret**
4. The Browse API uses client credentials OAuth — no user consent needed

## 2. Create the Discord webhook

1. In your Discord server, go to a channel → Edit → Integrations → Webhooks
2. Create a webhook, copy the URL

## 3. Create the 1Password item

Create a new item in 1Password named **`ebay-watcher`** with these fields:

| Field name           | Value                          |
|----------------------|--------------------------------|
| `client_id`          | Your eBay App ID               |
| `client_secret`      | Your eBay Client Secret        |
| `discord_webhook_url`| Your Discord webhook URL       |

This matches the ExternalSecret mapping in `externalsecret.yaml`.

## 4. Add the app repo to your GitHub account

```bash
gh repo create phekno/ebay-watcher --public
cd ebay-watcher
git init && git add . && git commit -m "feat: initial commit"
git remote add origin git@github.com:phekno/ebay-watcher.git
git push -u origin main
```

GitHub Actions will build and push to GHCR automatically.

## 5. Add manifests to home-ops

Copy the `kubernetes/apps/utilities/ebay-watcher/` directory into your home-ops repo.

Add the Flux Kustomization from `kubernetes/flux/apps/ebay-watcher.yaml` to wherever
your cluster-level Kustomizations live (check your existing pattern — likely
`kubernetes/flux/apps/` or similar).

## 6. Environment variables reference

| Variable           | Required | Default       | Description                              |
|--------------------|----------|---------------|------------------------------------------|
| `EBAY_CLIENT_ID`   | ✅       | —             | eBay Browse API client ID                |
| `EBAY_CLIENT_SECRET`| ✅      | —             | eBay Browse API client secret            |
| `DISCORD_WEBHOOK_URL`| ✅     | —             | Discord channel webhook URL              |
| `SEARCH_QUERIES`   | ✅       | —             | Comma-separated search queries           |
| `MAX_PRICE`        | ✅       | —             | Alert threshold in USD                   |
| `POLL_INTERVAL`    | ❌       | `1h`          | How often to poll (Go duration string)   |
| `DATABASE_PATH`    | ❌       | `/data/seen.db`| SQLite file path                        |
| `LISTEN_ADDR`      | ❌       | `:8080`       | HTTP server listen address               |

## 7. Access the UI

After deploying, the dashboard will be at:
`https://ebay-watcher.phekno.io`

It's wired to `envoy-internal` so it's only accessible on your internal network.
