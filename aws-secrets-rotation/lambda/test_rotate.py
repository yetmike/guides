"""Local check: the 4 steps against a real Postgres, Secrets Manager mocked by moto.

docker run -d --rm --name rot-pg -e POSTGRES_PASSWORD=admin -p 55432:5432 postgres:17
pip install moto boto3 pg8000 && python test_rotate.py
"""
import json
import os
import uuid

os.environ.setdefault("AWS_DEFAULT_REGION", "eu-west-1")
from moto import mock_aws  # noqa: E402


@mock_aws
def main():
    import rotate
    rotate.SSL = False  # local Postgres has no TLS
    rotate.sm = sm = __import__("boto3").client("secretsmanager")

    admin = rotate.pg.Connection("postgres", password="admin", host="127.0.0.1", port=55432)
    admin.run("DROP ROLE IF EXISTS app")
    admin.run("CREATE ROLE app LOGIN PASSWORD 'first-password'")

    secret = {"engine": "postgres", "host": "127.0.0.1", "port": 55432, "username": "app",
              "password": "first-password", "dbname": "postgres"}
    arn = sm.create_secret(Name="demo", SecretString=json.dumps(secret))["ARN"]
    token = str(uuid.uuid4())
    # Real Secrets Manager turns rotation on and pre-stages an empty AWSPENDING version
    # with the token before calling createSecret. moto doesn't, so fake that view.
    describe = sm.describe_secret

    def fake_describe(**kw):
        meta = describe(**kw)
        meta["RotationEnabled"] = True
        meta["VersionIdsToStages"].setdefault(token, ["AWSPENDING"])
        return meta
    sm.describe_secret = fake_describe

    for step in ["createSecret", "createSecret", "setSecret", "setSecret", "testSecret", "finishSecret", "finishSecret"]:
        rotate.lambda_handler({"SecretId": arn, "ClientRequestToken": token, "Step": step}, None)

    new = rotate.get(arn, "AWSCURRENT")
    assert new["password"] != "first-password"
    assert rotate.get(arn, "AWSPREVIOUS")["password"] == "first-password"
    assert rotate.can_login(new)
    assert not rotate.can_login(secret)  # old password is dead
    stages = sm.describe_secret(SecretId=arn)["VersionIdsToStages"]
    assert "AWSCURRENT" in stages[token], stages
    print("ok: 4 steps, retries are idempotent, old password rejected")


main()
