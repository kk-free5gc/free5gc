---
description: Smart Serena setup that automatically reads paths from .mcp.json configuration
category: setup
---

Please perform these Serena setup steps automatically using paths from .mcp.json:

1. **Load Configuration**: Use the initial_instructions tool to load Serena's configuration

2. **Check Project Status**: Use get_active_project to verify the project is activated

3. **Read Configuration Paths**: Use execute_shell_command to extract paths from .mcp.json:
   ```
   echo "Reading configuration from .mcp.json..."
   if [ -f .mcp.json ]; then
     SERENA_DIR=$(jq -r '.mcpServers.serena.args[] | select(. | test("^/.*serena$"))' .mcp.json 2>/dev/null || grep -oE '"/[^"]*serena"' .mcp.json | head -1 | tr -d '"')
     PROJECT_DIR=$(jq -r '.mcpServers.serena.args[] | select(. | test("^/.*") and (. | test("serena") | not))' .mcp.json 2>/dev/null || grep -A5 '"--project"' .mcp.json | grep -oE '"/[^"]*"' | head -1 | tr -d '"')
     echo "Serena directory: $SERENA_DIR"
     echo "Project directory: $PROJECT_DIR"
   else
     echo "No .mcp.json found - using current directory as project"
     PROJECT_DIR=$(pwd)
   fi
   ```

4. **Check Indexing**: Use execute_shell_command to check if project indexing exists:
   ```
   ls -la .serena/index* 2>/dev/null || echo "No index found - will create one"
   ```

5. **Create Index Dynamically**: Use execute_shell_command to create project index using discovered paths:
   ```
   # Read paths from .mcp.json
   SERENA_DIR=$(jq -r '.mcpServers.serena.args[] | select(. | test("^/.*serena$"))' .mcp.json 2>/dev/null || grep -oE '"/[^"]*serena"' .mcp.json | head -1 | tr -d '"')
   PROJECT_DIR=$(pwd)
   
   if [ -n "$SERENA_DIR" ] && [ -d "$SERENA_DIR" ]; then
     echo "Creating index using Serena from: $SERENA_DIR"
     echo "For project: $PROJECT_DIR"
     uv run --directory "$SERENA_DIR" index-project "$PROJECT_DIR"
   else
     echo "Could not find Serena directory in .mcp.json - please check configuration"
   fi
   ```

6. **Create Project Config Directory**: Use execute_shell_command to ensure .serena directory exists:
   ```
   mkdir -p .serena
   ```

7. **Create Project Configuration**: Use create_text_file to create .serena/project.yml with smart settings:
   ```yaml
   name: "$(basename $(pwd))"
   
   # Universal optimization settings
   context_management:
     max_context_files: 15
     prioritize_recent_files: true
     
   # Smart onboarding that adapts to project type
   onboarding:
     ignore_patterns:
       # Generic patterns
       - "vendor/*"
       - "node_modules/*"
       - "build/*"
       - "dist/*"
       - ".git/*"
       # Go-specific
       - "*.pb.go"
       # C/C++ specific  
       - "*.o"
       - "*.a"
       - "cmake-build-*/*"
       # Python specific
       - "__pycache__/*"
       - "*.pyc"
       # Documentation and tests
       - "docs/*"
       - "test/*"
       - "tests/*"
   
   # Memory management
   memory_settings:
     auto_cleanup_old_memories: true
     max_memories: 20
   ```

8. **Check Onboarding**: Use check_onboarding_performed to see if onboarding was completed

9. **Perform Smart Onboarding**: If onboarding wasn't performed, use the onboarding tool to analyze the project structure while ignoring common build/dependency directories

10. **Show Final Status**: Use get_current_config to display the complete setup configuration

11. **Configuration Summary**: Use execute_shell_command to show the paths being used:
    ```
    echo "=== Configuration Summary ==="
    echo "Project: $(pwd)"
    echo "Serena: $(jq -r '.mcpServers.serena.args[] | select(. | test("^/.*serena$"))' .mcp.json 2>/dev/null || echo 'Path from .mcp.json')"
    echo "Index created: $(ls .serena/index* 2>/dev/null | wc -l) files"
    echo "Ready for development!"
    ```

This setup automatically reads your Serena and project paths from .mcp.json, making it portable across different environments and projects.