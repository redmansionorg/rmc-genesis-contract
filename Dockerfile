# Foundry + Node.js Development Environment
FROM ubuntu:22.04

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    nodejs \
    npm \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Foundry
RUN curl -L https://foundry.paradigm.xyz | bash && \
    /root/.foundry/bin/foundryup

# Add Foundry to PATH
ENV PATH="/root/.foundry/bin:${PATH}"

# Set working directory
WORKDIR /app

# Copy package files first (for layer caching)
COPY package*.json ./

# Install Node.js dependencies
RUN npm install

# Copy the rest of the project
COPY . .

# Install Foundry dependencies (forge-std)
RUN git config --global user.email "docker@localhost" && \
    git config --global user.name "Docker" && \
    forge install foundry-rs/forge-std || true

# Default command
CMD ["forge", "build"]
