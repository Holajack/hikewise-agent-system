FROM node:22-slim

WORKDIR /app

# Install curl for healthcheck
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Copy package files
COPY dashboard/package*.json ./dashboard/

# Install dependencies
WORKDIR /app/dashboard
RUN npm ci --omit=dev

# Copy dashboard source
COPY dashboard/ ./

# Copy other project files
WORKDIR /app
COPY agent/ ./agent/
COPY maestro/ ./maestro/
COPY templates/ ./templates/

# Create data directories
RUN mkdir -p data agent/logs maestro/results

# Run as non-root
RUN groupadd -r hikewise && useradd -r -g hikewise -d /app hikewise
RUN chown -R hikewise:hikewise /app
USER hikewise

WORKDIR /app/dashboard

EXPOSE 3847

CMD ["node", "server.js"]
