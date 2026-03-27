# Google Cloud Storage Setup

## Create Service Account Credentials

### Option 1: gcloud CLI

```bash
# 1. Login
gcloud auth login adrianibanez99@gmail.com

# 2. Create a project (or use existing)
gcloud projects create naturecounts-gcs --name="NatureCounts"
gcloud config set project naturecounts-gcs

# 3. Enable Cloud Storage API
gcloud services enable storage.googleapis.com

# 4. Create service account
gcloud iam service-accounts create naturecounts-sa \
  --display-name="NatureCounts Video Access"

# 5. Grant it storage access
gcloud projects add-iam-policy-binding naturecounts-gcs \
  --member="serviceAccount:naturecounts-sa@naturecounts-gcs.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer"

# 6. Generate the JSON key (this is what you paste in the UI)
gcloud iam service-accounts keys create ~/sa-key.json \
  --iam-account=naturecounts-sa@naturecounts-gcs.iam.gserviceaccount.com

# 7. Print it
cat ~/sa-key.json
```

### Option 2: Google Cloud Console

1. Go to https://console.cloud.google.com
2. Sign in with your Google account
3. Create or select a project
4. Navigate to **IAM & Admin > Service Accounts > Create**
5. Grant the **Storage Object Viewer** role (or **Storage Admin** for read/write)
6. Click the service account > **Keys > Add Key > JSON**
7. Download the JSON file

## Add Bucket in NatureCounts

1. Open `/videos` in the web UI
2. Click the **GCS** toggle in the "Browse Files" header
3. Click **+ Add Bucket**
4. Fill in:
   - **Display Name** — label for this bucket (e.g. "Marine Cam East")
   - **GCS Bucket ID** — the actual GCS bucket name (e.g. "naturecounts-videos")
   - **Path Prefix** — optional subfolder filter (e.g. "cameras/east/")
   - **Service Account JSON** — paste the full contents of the downloaded JSON key
5. Click **Test Connection** to verify access
6. Click **Save Bucket**

## Multi-Tenant Usage

Each bucket has its own service account credentials. This allows:

- Different GCP projects per bucket
- Different permission levels per data source
- Isolated access — revoking one key doesn't affect others

To add another tenant's bucket, repeat the steps above with their own service account JSON.

## Roles Reference

| Role | Access |
|------|--------|
| `roles/storage.objectViewer` | Read-only (browse + play videos) |
| `roles/storage.objectAdmin` | Read/write objects |
| `roles/storage.admin` | Full bucket management |

For video browsing and processing, **Storage Object Viewer** is sufficient.
