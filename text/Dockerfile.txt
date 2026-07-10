# Use a slim Python 3.11 base image to keep the image size small
FROM python:3.11-slim

# Set working directory inside the container
WORKDIR /app

# Copy and install dependencies first so Docker can cache this layer
# (only re-runs when requirements.txt changes, not on every code change)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source files
COPY classifier.py .
COPY bigquery_io.py .

# Cloud Run Jobs execute a command to completion and exit.
# The --bigquery flag tells the script to read from user_prompts,
# classify, and write to user_prompts_enriched.
ENTRYPOINT ["python", "classifier.py", "--bigquery"]
