---
description: Serena setup + onboarding with ignored_paths review before indexing
category: setup
---

Please perform these Serena setup steps automatically for the current project, with my custom indexer script and a review/confirmation of ignored paths before indexing:

1) **Load Serena config**
   - Use `initial_instructions` to load Serena’s configuration.

2) **Verify active project**
   - Use `get_active_project` to confirm the current project is active.

3) **Check onboarding status**
   - Use `check_onboarding_performed`.
   - If not performed, run `onboarding` (smart scan; ignore only very common system/vendor/build dirs).

4) **Show `.serena/project.yml` and ignored_paths**  
   - Use `execute_shell_command`:
     ```bash
     [ -f .serena/project.yml ] && (echo "===== Existing .serena/project.yml found =====" && grep -A20 '^ignored_paths:' .serena/project.yml || echo "No ignored_paths section found") || (echo "===== No .serena/project.yml found — creating minimal config =====" && mkdir -p .serena && echo "ignored_paths: []" > .serena/project.yml); echo ">>> Review the above ignored_paths and /home/wnc/Downloads/source_code/free5gc_4.0.1/free5gc/serena_index_free5gc.sh path/variable setting. Tell me 'continue' to proceed to indexing steps."
     ```
   - **Stop here** and wait for my confirmation before continuing to Step 5.

---

**After I confirm "continue":**

5) **Ensure indexer is executable**
   - Use `execute_shell_command`:
     ```bash
     chmod +x "/home/wnc/Downloads/source_code/free5gc_4.0.1/free5gc/serena_index_free5gc.sh" || true
     ```

6) **Run indexing (staged by default)** 
   - Please be patient, this may take up to 60 minutes, unless you have run it manually before.
   - If I say "staged", run:
     ```bash
     "/home/wnc/Downloads/source_code/free5gc_4.0.1/free5gc/serena_index_free5gc.sh" --workspace staged
     ```
   - If I say "full workspace", run:
     ```bash
     "/home/wnc/Downloads/source_code/free5gc_4.0.1/free5gc/serena_index_free5gc.sh" --workspace full
     ```

7) **Show index status**
   - Use `execute_shell_command`:
     ```bash
     ls -la .serena 2>/dev/null || echo ".serena directory not found"; test -d .serena && (echo "Index files:"; ls -la .serena/index* 2>/dev/null || echo "No index* files (ok)")
     ```

8) **Show Serena config**
   - Use `get_current_config`.

9) **Summary reminder**
   - State that onboarding is complete (if missing before) and that the Serena index was built via the custom script after you confirmed the ignored paths.

### Build reminder — Disable Go workspace mode when compiling (not for indexing)

When you want to **compile/run** an individual NF module (so it respects its own `go.mod` versions), **disable workspace mode**:

```bash
GOWORK=off make
# or temporarily move the workspace file:
mv go.work go.work.bak
# (restore when you need Serena/monorepo-wide indexing again)
# This avoids cross-module version conflicts (e.g., github.com/free5gc/openapi v1.0.8 vs v1.1.0) caused by Go workspace’s single dependency graph (MVS).
```

### Refer to below for more Serena project-level settings/parameters:

/home/wnc/Downloads/source_code/serena/.serena/project.yml
