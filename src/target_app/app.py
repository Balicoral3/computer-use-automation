"""Mock legacy bank back-office app.

Intentionally built to feel like a 2000s-era server-rendered enterprise app:
  - layout via <table>, not CSS grid
  - main content inside an <iframe>
  - no data-testid, no semantic ARIA
  - generated-looking class names
  - a few runtime error states to exercise the replay engine
"""

from __future__ import annotations

import os
import random
import time
from functools import wraps

from flask import (
    Flask,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

from .data import MEMBERS, VALID_USERS

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET", "dev-only-not-for-production")


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not session.get("user"):
            return redirect(url_for("login", next=request.path))
        return fn(*args, **kwargs)
    return wrapper


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        user = request.form.get("username", "").strip()
        pw = request.form.get("password", "")
        if VALID_USERS.get(user) == pw:
            session["user"] = user
            return redirect(url_for("home"))
        error = "Invalid username or password."
    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
@login_required
def home():
    return render_template("base.html", user=session["user"], content_url=url_for("search"))


@app.route("/search", methods=["GET", "POST"])
@login_required
def search():
    results = None
    query = ""
    if request.method == "POST":
        query = request.form.get("q", "").strip()
        results = [MEMBERS[query]] if query in MEMBERS else []
    return render_template("search.html", query=query, results=results)


@app.route("/member/<member_id>")
@login_required
def member_detail(member_id: str):
    if member_id == "00000":
        return render_template(
            "error.html", code="PERMISSION_DENIED",
            message="You do not have permission to view this record.",
        ), 403
    m = MEMBERS.get(member_id)
    if m is None:
        return render_template(
            "error.html", code="NOT_FOUND",
            message=f"No member found with ID {member_id}.",
        ), 404
    return render_template("member_detail.html", member=m)


@app.route("/member/<member_id>/subaccount/new", methods=["GET", "POST"])
@login_required
def subaccount_new(member_id: str):
    m = MEMBERS.get(member_id)
    if m is None:
        return render_template(
            "error.html", code="NOT_FOUND",
            message=f"No member found with ID {member_id}.",
        ), 404
    if m.status == "restricted":
        return render_template(
            "error.html", code="PERMISSION_DENIED",
            message="Account is restricted; cannot open new sub-accounts.",
        ), 403

    if request.method == "POST":
        sub_type = request.form.get("sub_type", "").strip()
        initial = request.form.get("initial_deposit", "").strip()
        nickname = request.form.get("nickname", "").strip()

        errors = []
        if not sub_type:
            errors.append("Sub-account type is required.")
        if not initial:
            errors.append("Initial deposit is required.")
        else:
            try:
                amt = float(initial)
                if amt < 25.0:
                    errors.append("Initial deposit must be at least $25.00.")
            except ValueError:
                errors.append("Initial deposit must be a number.")

        if errors:
            return render_template(
                "subaccount_form.html", member=m, errors=errors,
                sub_type=sub_type, initial=initial, nickname=nickname,
            ), 400

        return render_template(
            "subaccount_confirm.html", member=m,
            sub_type=sub_type, initial=initial, nickname=nickname,
        )

    return render_template(
        "subaccount_form.html", member=m, errors=None,
        sub_type="", initial="", nickname="",
    )


@app.route("/_sim/slow")
@login_required
def sim_slow():
    time.sleep(random.uniform(3.0, 6.0))
    return render_template(
        "error.html", code="SLOW", message="This page was slow to load."
    )


@app.route("/_sim/dialog")
@login_required
def sim_dialog():
    return render_template(
        "error.html", code="DIALOG",
        message="An unexpected dialog appeared.",
    ), 200


@app.route("/_sim/timeout")
@login_required
def sim_timeout():
    session.clear()
    return redirect(url_for("login"))


if __name__ == "__main__":
    port = int(os.environ.get("TARGET_APP_PORT", "5000"))
    app.run(host="127.0.0.1", port=port, debug=False)