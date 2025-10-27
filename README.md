# QB Jump Server

## Architecture

```
┌─────────────┐
│   Browser   │
└──────┬──────┘
       │ HTTPS
       ▼
┌─────────────────────────────────────┐
│     QB Jump Server (Nginx)     │
│  ┌──────────────────────────────┐   │
│  │   Lua Request Handler        │   │
│  │  ├─ Authentication (OIDC)    │   │
│  │  ├─ Session Manager          │   │
│  │  ├─ Service Router           │   │
│  │  └─ Access Monitor           │   │
│  └──────────────────────────────┘   │
└───────┬─────────────────┬───────────┘
        │                 │
   ┌────▼────┐       ┌────▼────────┐
   │ HTTP    │       │ SSH (ttyd)  │
   │ Services│       │ Sessions    │
   └─────────┘       └─────────────┘
```

**Core Components:**
- **Nginx + Lua** - High-performance request handling and routing
- **SQLite** - Local state management (sessions, permissions, monitoring)
- **Keycloak** - Identity and access management (OIDC provider)
- **ttyd** - Web-based SSH terminal emulator

## Roles and Permissions

The QB Jump Server uses three primary roles that should be configured in your OIDC provider (Keycloak):

- **`jumpserver:admin`** - Full system access and administration privileges
  - Access to administration dashboard
  - Manage services (HTTP/SSH)
  - Configure permissions and role assignments
  - View monitoring and audit logs
  - Bypass service-level access restrictions

- **`jumpserver:audit`** - Development/audit access with elevated privileges
  - Access to monitoring and audit logs
  - View service configurations
  - Standard user service access

- **`jumpserver:user`** - Standard user access to approved services
  - Access only to explicitly permitted services
  - No administrative capabilities

**Configuring Roles in Keycloak:**

To enable admin access, you need to create a user with the `jumpserver:admin` role. This can be configured in Keycloak either as:
- **Realm Role**: Create a realm-level role named `jumpserver:admin` and assign it to users
- **Client Scope**: Add `jumpserver:admin` to the client roles for the jump-server client and assign to users

The Jump Server reads these roles from the OIDC token claims and enforces access control accordingly.

## Installation

### Deployment Options

Choose the appropriate deployment based on your infrastructure:

#### Option 1: Full Deployment (with Keycloak)
Use this option if you **don't have** an existing Keycloak instance. This deploys both the QB Jump Server and Keycloak together.

**Includes:**
- QB Jump Server (Nginx + Lua)
- Keycloak (official image from quay.io)
- PostgreSQL (for Keycloak)
- All required networking and dependencies

**Step 1: Configure environment file**
```bash
# Copy environment template for full deployment
cp env/full .env

# Edit .env with your settings (host, ports, OIDC client secret, etc.)
nano .env
```

**Step 2: Start Keycloak and database only**
```bash
docker compose -f docker-compose-full.yml up -d keycloak-db keycloak
```

**Step 3: Configure Keycloak**

Wait for Keycloak to start, then access the admin console:

Login with credentials from `.env`:
- Username: `admin` (KEYCLOAK_ADMIN)
- Password: `admin` (KEYCLOAK_ADMIN_PASSWORD)

Configure the following:

1. **Create Realm:**
   - Click dropdown (top-left) → "Create Realm"
   - Name: `jump-server` (must match `OIDC_REALM` in env)
   - Click "Create"

2. **Create Client:**
   - Go to "Clients" → "Create client"
   - Client ID: `jump-server` (must match `OIDC_CLIENT_ID` in env.dev)
   - Client authentication: **ON**
   - Valid redirect URIs: `https://your-jump-server-host:8443/*`
   - Web origins: `https://your-jump-server-host:8443`
   - Click "Save"
   - Go to "Credentials" tab → Copy the **Client Secret**

3. **Update Jump Server Configuration:**
   - Edit `.env` file
   - Set `OIDC_CLIENT_SECRET` to the secret you copied
   - Update `JUMP_SERVER_HOST` and `OIDC_BASE_URL` if needed

4. **Create Roles:**
   - Go to "Realm roles" → "Create role"
   - Create the following roles:
     - `jumpserver:admin` (for administrators)
     - `jumpserver:audit` (for developers/auditors)
     - `jumpserver:user` (for standard users)
   - Alternatively, create these as client roles under the `jump-server` client

5. **Create Users:**
   - Go to "Users" → "Add user"
   - Create user accounts
   - Set credentials in "Credentials" tab
   - Assign appropriate roles in "Role mapping" tab (e.g., `jumpserver:admin` for admin access)

**Step 4: Start Jump Server**
```bash
docker compose -f docker-compose-full.yml up -d jump-server
```

Or restart everything:
```bash
docker compose -f docker-compose-full.yml up -d
```

#### Option 2: Standalone Deployment (Jump Server only)
Use this option if you **already have** a Keycloak instance running in your infrastructure. This deploys only the QB Jump Server and connects to your existing Keycloak.

**Setup:**
```bash
# Copy environment template for standalone deployment
cp env/standalone .env

# Edit .env with your existing Keycloak settings
nano .env
```

**Deploy:**
```bash
docker compose -f docker-compose-cloud.yml up -d
```

**Includes:**
- QB Jump Server (Nginx + Lua)

**Configuration required:**
- Update `.env` with your existing Keycloak connection details:
  - `OIDC_BASE_URL` - Your Keycloak instance URL
  - `OIDC_CLIENT_SECRET` - Client secret from your Keycloak client
  - `OIDC_REALM` - Realm name in your Keycloak
- Ensure your Keycloak has the appropriate client configured with correct redirect URIs

### Quick Start Guide

1. **Clone the repository**
```bash
git clone https://github.com/Quantum-Blockchains/qb-jumpserver.git
cd qb-jumpserver
```

2. **Configure environment**
```bash
# For full deployment (with Keycloak)
cp env/full .env

# OR for standalone (without Keycloak)
cp env/standalone .env

# Edit .env with your settings
nano .env
```

3. **Configure services** (optional - can be done after deployment)
```bash
cp services.json.example services.json
# Add your HTTP/SSH services
```

**Note:** The server can be configured to run with HTTPS by providing SSL/TLS certificates. Set the appropriate environment variables (`SSL_CERT_PATH`, `SSL_KEY_PATH`) and enable HTTPS in the configuration.

**Example - Generate self-signed certificate:**
```bash
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes -subj "/CN=qb-jumpserver"
```

4. **Deploy**
Choose your deployment option based on your infrastructure:

**Full deployment (with Keycloak):**
```bash
# Start Keycloak first
docker compose -f docker-compose-full.yml up -d keycloak-db keycloak

# Configure Keycloak (see steps in Option 1 above)

# Start Jump Server
docker compose -f docker-compose-full.yml up -d
```

**Standalone deployment:**
```bash
docker compose -f docker-compose-cloud.yml up -d
```

5. **Access the dashboard**
```
https://your-jump-server-host:8443
```