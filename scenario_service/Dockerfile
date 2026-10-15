# Use a slim Python image as the base for building and running
FROM python:3.12

# Create the final application directory
WORKDIR /app

# Build deps + Microsoft ODBC Driver 18 for SQL Server (required by pyodbc for db-360 load)
# + kubectl/git, needed by demo_flows/*/trigger.sh scripts the
# scenario runner shells out to for the "script" scenario type.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    zlib1g-dev \
    unixodbc-dev \
    curl \
    gnupg \
    lsb-release \
    git \
    gettext-base \
    jq \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft-prod.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends \
        libodbc2 \
        msodbcsql18 \
    && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && rm -rf /var/lib/apt/lists/*

# Copy the requirements file and install dependencies
COPY scenario_service/requirements.txt .
RUN pip install -r requirements.txt

RUN mkdir locust
COPY scenario_service/locust /locust

# Copy the application code
COPY scenario_service /app

# demo_flows/ holds each scenario's trigger.sh + shared lib — the runner
# shells out to these for the "script" scenario type. Trigger scripts do
# `git -C ... rev-parse --show-toplevel` to find REPO_ROOT
# (for an optional .env load and to locate
# utils/scripts/new_relic/send_change_tracking_marker.py), so it needs a git
# working tree root. An empty `git init` is enough; repo history is not copied.
# .env itself is deliberately not baked in here — it's runtime-only, sourced from the pod's own environment
# if the NR_USER_API_KEY/NR_ACCOUNT_ID change-tracking marker is wanted.
RUN git init -q /app
COPY demo_flows /app/demo_flows
COPY utils /app/utils
COPY k8s/overlays/noisy-neighbor /app/k8s/overlays/noisy-neighbor
RUN git config --global --add safe.directory /app

# Expose the port the app runs on
EXPOSE 8000

# Command to run the application with gunicorn and uvicorn workers
# CMD ["gunicorn", "-w", "4", "-k", "uvicorn.workers.UvicornWorker", "-b", "0.0.0.0:8000", "scenario_service.scenario_service:app"]
CMD ["uvicorn", "scenario_service:app", "--host", "0.0.0.0", "--port", "8000"]
