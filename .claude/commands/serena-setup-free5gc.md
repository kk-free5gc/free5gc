---
description: Universal Serena setup with indexing for optimal performance on any project size
category: setup
---

Please perform these Serena setup steps automatically (optimized for all project sizes):

1. **Load Configuration**: Use the initial_instructions tool to load Serena's configuration

2. **Check Project Status**: Use get_active_project to verify the project is activated

3. **Check Indexing**: Use execute_shell_command to check if project indexing exists:
   ```
   ls -la .serena/index* 2>/dev/null || echo "No index found - will create one"
   ```

4. **Create Index for Performance**: Use execute_shell_command to create/update project index:
   ```
   uv run --directory /home/loren/Downloads/source_code/serena index-project $(pwd)
   ```

5. **Create Project Config Directory**: Use execute_shell_command to ensure .serena directory exists:
   ```
   mkdir -p .serena
   ```

6. **Create Basic Project Configuration**: Use create_text_file to create .serena/project.yml with optimized settings:
   ```yaml
   name: project
   
   # Universal optimization settings
   context_management:
     max_context_files: 10
     prioritize_recent_files: true
     
   # Smart onboarding for any project
   onboarding:
     ignore_patterns:
       - "node_modules/*"
       - "vendor/*"
       - "build/*"
       - "dist/*"
       - ".git/*"
       - "*.min.js"
       - "*.bundle.*"
   
   # Memory management
   memory_settings:
     auto_cleanup_old_memories: true
     max_memories: 15
   ```

7. **Check Onboarding**: Use check_onboarding_performed to see if onboarding was completed

8. **Perform Smart Onboarding**: If onboarding wasn't performed, use the onboarding tool to analyze the project structure while ignoring common build/dependency directories

9. **Show Final Status**: Use get_current_config to display the complete setup configuration

10. **Performance Note**: Remind that indexing has been created for optimal performance on subsequent sessions

This setup works optimally for projects of any size - small, medium, or large.