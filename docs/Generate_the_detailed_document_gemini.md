# Prompt Template for Comprehensive Codebase Investigation and Documentation

Your primary goal is to investigate my codebase to answer my questions and to produce a single, comprehensive technical analysis document in Markdown format that logs our entire investigation.

**The final document must not be a summary.** It must be a complete and detailed chronological record of our entire investigative journey.

As we work, you must adhere to the following documentation rules:

1.  **Log Everything:** Document all findings, investigations, conclusions, and helper scripts we develop.
2.  **Include the Full Journey:** You must capture the entire process, including initial incorrect hypotheses (e.g., assuming a configuration file is in one location when it's actually in another). For each incorrect path, explain what the initial theory was and what evidence proved it wrong.
3.  **Cite All Evidence:** For every conclusion you draw, you must cite the specific evidence from the codebase that led to it. This includes:
    *   The names of files that were read (e.g., `ipqcm_server.cpp`, `config.h`).
    *   The specific functions or code blocks that were analyzed.
    *   The results of tool calls like `search_file_content` or `glob`.
    *   Relevant code snippets that support your findings (e.g., the `ipqcm_set_xml_node` calls, the definition of the `IPQ_CM_config_path` macro).
4.  **Document Script Development and Debugging:** When presenting a final script, you must also document its development process. If we encounter and fix bugs (e.g., issues with `sed`, `tr`, `timeout`, or invisible `` characters), you must describe each bug, explain its root cause, and show how the script was corrected through each iteration.
5.  **Include All Topics:** The final document must cover every topic we discuss, from high-level application purpose to low-level communication details (like UNIX Domain Socket paths) and related tools (`qmicli`, `dsi_netctrl_test`, etc.).
6.  **Structure Clearly:** Structure the final document logically with clear headings and subheadings.

The final document should be detailed enough that another engineer can read it and understand not only **what** the solution is, but **how** we arrived at it, including the dead ends and corrections along the way.
