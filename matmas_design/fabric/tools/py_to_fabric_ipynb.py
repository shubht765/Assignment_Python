"""Convert a percent-format notebook source (# %% / # %% [markdown]) into a Fabric .ipynb.

The notebook metadata is the one Fabric writes for the team's Python-kernel notebooks
(ingest_external_files): Jupyter Python kernel, default lakehouse lh_p2o_intg_dev in ws_p2o_intg_dev.
A cell header with tags=["parameters"] becomes the parameter cell (pipeline base parameters).

Usage: python3 py_to_fabric_ipynb.py fabric/nb_matmas_process.py fabric/nb_matmas_process.ipynb
"""
import json, re, sys

LAKEHOUSE_ID = "b2b34438-2cbb-468b-894c-62b0803c60f3"          # lh_p2o_intg_dev
WORKSPACE_ID = "04017791-0d3c-4785-888e-a955923e2130"          # ws_p2o_intg_dev
META = {
    "kernelspec": {"name": "jupyter", "display_name": "Jupyter"},
    "language_info": {"name": "python"},
    "microsoft": {"language": "python", "language_group": "jupyter_python",
                  "ms_spell_check": {"ms_spell_check_language": "en"}},
    "nteract": {"version": "nteract-front-end@1.0.0"},
    "kernel_info": {"name": "jupyter", "jupyter_kernel_name": "python3.12"},
    "spark_compute": {"compute_id": "/trident/default",
                      "session_options": {"conf": {"spark.synapse.nbs.session.timeout": "1200000"}}},
    "dependencies": {"lakehouse": {"known_lakehouses": [{"id": LAKEHOUSE_ID}],
                                   "default_lakehouse": LAKEHOUSE_ID,
                                   "default_lakehouse_name": "lh_p2o_intg_dev",
                                   "default_lakehouse_workspace_id": WORKSPACE_ID}},
}


def convert(src_path, out_path):
    text = open(src_path, encoding="utf-8").read()
    parts = re.split(r"^# %%(.*)$", text, flags=re.M)
    cells, n = [], 0
    for header, body in zip(parts[1::2], parts[2::2]):
        body = body.strip("\n")
        if not body.strip():
            continue
        cid = f"cell{n:02d}"; n += 1
        if "[markdown]" in header:
            lines = [re.sub(r"^# ?", "", ln) for ln in body.splitlines()]
            cells.append({"cell_type": "markdown", "metadata": {}, "id": cid,
                          "source": [ln + "\n" for ln in lines[:-1]] + lines[-1:]})
        else:
            meta = {"microsoft": {"language": "python", "language_group": "jupyter_python"}}
            if 'tags=["parameters"]' in header:
                meta["tags"] = ["parameters"]
            lines = body.splitlines()
            cells.append({"cell_type": "code", "execution_count": None, "metadata": meta, "id": cid,
                          "outputs": [], "source": [ln + "\n" for ln in lines[:-1]] + lines[-1:]})
    nb = {"cells": cells, "metadata": META, "nbformat": 4, "nbformat_minor": 5}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(nb, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"written {out_path}: {len(cells)} cells")


if __name__ == "__main__":
    convert(sys.argv[1], sys.argv[2])
