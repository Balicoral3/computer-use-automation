.RECIPEPREFIX = >

PYTHON ?= python
ARTIFACT_ID ?= lookup_member_balance

.PHONY: help setup serve discover replay replay-notfound test clean

help:
> @echo "make setup         - install deps + chromium"
> @echo "make serve         - run the mock bank app"
> @echo "make discover      - LLM discovery run (needs DEEPSEEK_API_KEY)"
> @echo "make replay        - deterministic replay (member 12345)"
> @echo "make replay-notfound  - replay with member 99999"
> @echo "make test          - run pytest"

setup:
> $(PYTHON) -m pip install -r requirements.txt
> $(PYTHON) -m playwright install chromium

serve:
> $(PYTHON) -m cli.serve_app

discover:
> $(PYTHON) -m cli.discover --artifact-id $(ARTIFACT_ID) --goal "Look up member 12345 and read their savings balance"

replay:
> $(PYTHON) -m cli.replay --artifact-id $(ARTIFACT_ID) --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=12345

replay-notfound:
> $(PYTHON) -m cli.replay --artifact-id $(ARTIFACT_ID) --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=99999

test:
> $(PYTHON) -m pytest -v

clean:
> $(PYTHON) -c "import shutil,pathlib;[shutil.rmtree(p,ignore_errors=True) for p in pathlib.Path('.').rglob('__pycache__')]"
> $(PYTHON) -c "import shutil;shutil.rmtree('.pytest_cache',ignore_errors=True)"