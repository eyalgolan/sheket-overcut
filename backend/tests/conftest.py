"""Shared pytest fixtures.

The contract fixtures load the read-only files in ``contract/``. The AWS
fixtures give every test a dummy AWS environment and, on request, an
in-memory DynamoDB table and S3 bucket from moto, so no test needs AWS
credentials or reaches a real endpoint (spec section 11).
"""

import json
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

CONTRACT_DIR = Path(__file__).resolve().parents[2] / "contract"

TABLE_NAME = "reports"
BUCKET_NAME = "sheket-blocklist-test"
# A test-only value. The real salt is deployment configuration, never in source.
TEST_IP_HASH_SALT = "test-only-salt-not-a-secret"


def load_contract(name):
    """Load and return a JSON file from ``contract/``. Never writes."""
    with open(CONTRACT_DIR / name, "r", encoding="utf-8") as fh:
        return json.load(fh)


@pytest.fixture(scope="session")
def contract_dir():
    return CONTRACT_DIR


@pytest.fixture(scope="session")
def contract_loader():
    return load_contract


@pytest.fixture(scope="session")
def corpus():
    return load_contract("corpus.json")


@pytest.fixture(scope="session")
def curated():
    return load_contract("curated.json")


def pytest_generate_tests(metafunc):
    if "normalize_case" in metafunc.fixturenames:
        cases = load_contract("corpus.json")["normalize"]
        # An empty list would silently skip the corpus test instead of failing.
        assert cases, "contract/corpus.json has no normalize cases"
        metafunc.parametrize(
            "normalize_case", cases, ids=[repr(c["in"]) for c in cases]
        )


class _NoAwsClient:
    """Stands in for the handlers' cached AWS clients outside moto.

    Any use fails the test, so a test that forgets ``ddb_table`` or
    ``s3_bucket`` (or a stub client) can never send a request to real AWS.
    """

    def __getattr__(self, name):
        raise AssertionError(
            "no moto: request ddb_table / s3_bucket or set a stub client"
        )


@pytest.fixture(autouse=True)
def aws_env(monkeypatch, tmp_path):
    """Replace any real AWS configuration with dummy values for every test.

    The handlers' cached clients are replaced with ``_NoAwsClient``; the
    ``ddb_table`` and ``s3_bucket`` fixtures reset them so moto clients are
    created instead.
    """
    from sheket import aggregate, report

    for name in (
        "AWS_PROFILE",
        "AWS_DEFAULT_PROFILE",
        "AWS_ENDPOINT_URL",
        "AWS_ENDPOINT_URL_DYNAMODB",
        "AWS_ENDPOINT_URL_S3",
    ):
        monkeypatch.delenv(name, raising=False)
    missing = str(tmp_path / "no-aws-config")
    monkeypatch.setenv("AWS_CONFIG_FILE", missing)
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", missing)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("IP_HASH_SALT", TEST_IP_HASH_SALT)
    monkeypatch.setattr(report, "_client", _NoAwsClient())
    monkeypatch.setattr(aggregate, "_ddb_client", _NoAwsClient())
    monkeypatch.setattr(aggregate, "_s3_client", _NoAwsClient())


@pytest.fixture
def ddb_table(aws_env):
    """Yield a moto DynamoDB table with the report handler's key schema.

    ``pk`` (HASH) and ``sk`` (RANGE) are strings; the Terraform table must
    match. The handlers' cached DynamoDB clients are reset on entry and exit
    so they are always created inside this moto context.
    """
    from sheket import aggregate, report

    with mock_aws():
        report._client = None
        aggregate._ddb_client = None
        client = boto3.client("dynamodb")
        client.create_table(
            TableName=TABLE_NAME,
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        try:
            yield client
        finally:
            report._client = None
            aggregate._ddb_client = None


@pytest.fixture
def s3_bucket(aws_env):
    """Yield a moto S3 client with an empty ``BUCKET_NAME`` bucket.

    The aggregate handler's cached S3 client is reset on entry and exit so it
    is always created inside this moto context. Combined with ``ddb_table``,
    the nested moto contexts share one in-memory backend.
    """
    from sheket import aggregate

    with mock_aws():
        aggregate._s3_client = None
        client = boto3.client("s3")
        client.create_bucket(Bucket=BUCKET_NAME)
        try:
            yield client
        finally:
            aggregate._s3_client = None
