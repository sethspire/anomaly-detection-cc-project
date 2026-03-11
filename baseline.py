#!/usr/bin/env python3
import json
import math
import boto3
from datetime import datetime
from typing import Optional

s3 = boto3.client("s3")

import logging
logger = logging.getLogger(__name__)

class BaselineManager:
    """
    Maintains a per-channel running baseline using Welford's online algorithm,
    which computes mean and variance incrementally without storing all past data.
    """

    def __init__(self, bucket: str, baseline_key: str = "state/baseline.json"):
        self.bucket = bucket
        self.baseline_key = baseline_key

    def load(self) -> dict:
        try:
            response = s3.get_object(Bucket=self.bucket, Key=self.baseline_key)
            return json.loads(response["Body"].read())
        except s3.exceptions.NoSuchKey:
            return {}

    def save(self, baseline: dict):
        baseline["last_updated"] = datetime.utcnow().isoformat()
        try:
            s3.put_object(
                Bucket=self.bucket,
                Key=self.baseline_key,
                Body=json.dumps(baseline, indent=2),
                ContentType="application/json"
            )
            logger.info("Saved new baseline to S3")
        except Exception as e:
            logger.exception(f"Failed to save baseline: {e}")
        
        # load log file and store in s3
        try:
            with open("/var/log/fastapi/anomaly_pipeline.log", "rb") as f:
                s3.put_object(
                    Bucket=self.bucket,
                    Key="logs/anomaly_pipeline.log",
                    Body=f,
                    ContentType="text/plain"
                )
            logger.info("Uploaded log file to S3")
        except FileNotFoundError:
            logger.warning("Log file not found for upload")
        except Exception as e:
            logger.exception(f"Failed to upload log file: {e}")

    def update(self, baseline: dict, channel: str, new_values: list[float]) -> dict:
        """
        Welford's online algorithm for numerically stable mean and variance.
        Each channel tracks: count, mean, M2 (sum of squared deviations).
        Variance = M2 / count, std = sqrt(variance).
        """
        if channel not in baseline:
            baseline[channel] = {"count": 0, "mean": 0.0, "M2": 0.0}

        state = baseline[channel]

        for value in new_values:
            state["count"] += 1
            delta = value - state["mean"]
            state["mean"] += delta / state["count"]
            delta2 = value - state["mean"]
            state["M2"] += delta * delta2

        # Only compute std once we have enough observations
        if state["count"] >= 2:
            variance = state["M2"] / state["count"]
            state["std"] = math.sqrt(variance)
        else:
            state["std"] = 0.0

        baseline[channel] = state
        return baseline

    def get_stats(self, baseline: dict, channel: str) -> Optional[dict]:
        return baseline.get(channel)
