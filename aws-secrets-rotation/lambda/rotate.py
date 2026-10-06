"""Secrets Manager rotation for a Postgres user (Neon), single user strategy.

Based on the AWS SecretsManagerRotationTemplate.
"""
import json
import logging
import ssl

import boto3
import pg8000.native as pg

log = logging.getLogger()
log.setLevel(logging.INFO)

sm = boto3.client("secretsmanager")
SSL = ssl.create_default_context()  # verify the server certificate


def lambda_handler(event, context):
    arn, token, step = event["SecretId"], event["ClientRequestToken"], event["Step"]

    meta = sm.describe_secret(SecretId=arn)
    if not meta["RotationEnabled"]:
        raise ValueError(f"Secret {arn} is not enabled for rotation")
    versions = meta["VersionIdsToStages"]
    if token not in versions:
        raise ValueError(f"Secret version {token} has no stage for rotation")
    if "AWSCURRENT" in versions[token]:
        log.info("version %s is already AWSCURRENT", token)
        return
    if "AWSPENDING" not in versions[token]:
        raise ValueError(f"Secret version {token} is not AWSPENDING")

    log.info("step=%s version=%s", step, token)
    if step == "createSecret":
        create_secret(arn, token)
    elif step == "setSecret":
        set_secret(arn, token)
    elif step == "testSecret":
        test_secret(arn, token)
    elif step == "finishSecret":
        finish_secret(arn, token)
    else:
        raise ValueError(f"Invalid step {step}")


def create_secret(arn, token):
    current = get(arn, "AWSCURRENT")
    try:
        get(arn, "AWSPENDING", token)
        log.info("createSecret: pending version already exists")
        return
    except sm.exceptions.ResourceNotFoundException:
        pass
    # Characters that break connection strings or shells stay out.
    pw = sm.get_random_password(PasswordLength=32, ExcludeCharacters="/@\"'\\:%")["RandomPassword"]
    sm.put_secret_value(
        SecretId=arn, ClientRequestToken=token,
        SecretString=json.dumps({**current, "password": pw}), VersionStages=["AWSPENDING"],
    )
    log.info("createSecret: new password stored as AWSPENDING")


def set_secret(arn, token):
    pending = get(arn, "AWSPENDING", token)
    if can_login(pending):
        log.info("setSecret: database already has the pending password")
        return

    current = get(arn, "AWSCURRENT")
    # The function is a privileged deputy: only change the same user on the same host.
    if (pending["username"], pending["host"]) != (current["username"], current["host"]):
        raise ValueError("pending and current secrets point to different users or hosts")

    conn = connect(current)
    if conn is None:
        # Same fallback as the AWS templates: the DB may still be on the previous password.
        previous = get(arn, "AWSPREVIOUS")
        conn = connect(previous)
        if conn is None:
            raise ValueError("setSecret: cannot log in with AWSCURRENT or AWSPREVIOUS")
    try:
        # ALTER ROLE takes no bind parameters, so quote with pg8000's helpers.
        conn.run(f"ALTER ROLE {pg.identifier(pending['username'])} WITH PASSWORD {pg.literal(pending['password'])}")
    finally:
        conn.close()
    log.info("setSecret: password changed in the database")


def test_secret(arn, token):
    conn = connect(get(arn, "AWSPENDING", token))
    if conn is None:
        raise ValueError("testSecret: cannot log in with the pending password")
    try:
        user = conn.run("SELECT current_user")[0][0]
    finally:
        conn.close()
    log.info("testSecret: logged in as %s with the new password", user)


def finish_secret(arn, token):
    versions = sm.describe_secret(SecretId=arn)["VersionIdsToStages"]
    current = next(v for v, stages in versions.items() if "AWSCURRENT" in stages)
    if current == token:
        log.info("finishSecret: already AWSCURRENT")
        return
    sm.update_secret_version_stage(
        SecretId=arn, VersionStage="AWSCURRENT", MoveToVersionId=token, RemoveFromVersionId=current,
    )
    log.info("finishSecret: AWSCURRENT moved to %s", token)


def get(arn, stage, token=None):
    kw = {"VersionStage": stage} | ({"VersionId": token} if token else {})
    return json.loads(sm.get_secret_value(SecretId=arn, **kw)["SecretString"])


def can_login(secret):
    conn = connect(secret)
    if conn:
        conn.close()
    return conn is not None


def connect(secret):
    """Open a Postgres connection over TLS. None means wrong password."""
    try:
        return pg.Connection(
            secret["username"], password=secret["password"], database=secret.get("dbname", "postgres"),
            host=secret["host"], port=int(secret.get("port", 5432)), ssl_context=SSL, timeout=10,
        )
    except pg.DatabaseError as e:
        if e.args and isinstance(e.args[0], dict) and e.args[0].get("C") == "28P01":  # invalid_password
            return None
        raise
