"""Static contract tests for Docker Hub documentation workflows."""
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
REUSABLE = ROOT / ".github/workflows/_docker_document.yml"
CALLER = ROOT / ".github/workflows/jetify-devbox-document.yml"
README = ROOT / "README.md"


def load_workflow(path: Path) -> dict:
    """Load YAML while keeping GitHub's `on` key as a string."""
    class Loader(yaml.SafeLoader):
        pass

    for first, mappings in list(Loader.yaml_implicit_resolvers.items()):
        Loader.yaml_implicit_resolvers[first] = [
            (tag, regex)
            for tag, regex in mappings
            if tag != "tag:yaml.org,2002:bool"
        ]
    return yaml.load(path.read_text(encoding="utf-8"), Loader=Loader)


class DockerDocumentWorkflowTests(unittest.TestCase):
    def test_reusable_workflow_contract_and_safe_markdown_resolution(self):
        workflow = load_workflow(REUSABLE)
        call = workflow["on"]["workflow_call"]
        inputs = call["inputs"]
        self.assertEqual(set(inputs), {"image", "docker-username", "markdown-file"})
        self.assertTrue(inputs["image"]["required"])
        self.assertTrue(inputs["docker-username"]["required"])
        self.assertEqual(inputs["markdown-file"]["default"], "README.md")
        self.assertIn("docker-password", call["secrets"])

        steps = workflow["jobs"]["docker-document"]["steps"]
        validation = next(step for step in steps if step["name"] == "Validate Markdown file")
        script = validation["run"]
        self.assertIn('realpath -e -- "$GITHUB_WORKSPACE"', script)
        self.assertIn('realpath -e -- "$workspace/$MARKDOWN_FILE"', script)
        self.assertIn('[[ ! -f "$markdown_file" || "$markdown_file" != "$workspace/"* ]]', script)

        credentials = next(step for step in steps if step["name"] == "Verify Docker Hub credentials")
        self.assertEqual(credentials["run"].strip().splitlines(), [
            'test -n "$DOCKER_USERNAME"',
            'test -n "$DOCKER_PASSWORD"',
        ])
        self.assertEqual(credentials["env"]["DOCKER_PASSWORD"], "${{ secrets['docker-password'] }}")

        action = next(step for step in steps if step["name"] == "Update Docker Hub description")
        self.assertEqual(action["uses"], "peter-evans/dockerhub-description@v5")
        self.assertEqual(action["with"]["password"], "${{ secrets['docker-password'] }}")
        self.assertEqual(action["with"]["repository"], "${{ inputs.image }}")
        self.assertEqual(action["with"]["readme-filepath"], "${{ steps.markdown.outputs.path }}")

    def test_main_caller_limits_trigger_paths_and_passes_contract(self):
        workflow = load_workflow(CALLER)
        push = workflow["on"]["push"]
        self.assertEqual(push["branches"], ["main"])
        self.assertEqual(push["paths"], [
            "README.md",
            ".github/workflows/jetify-devbox-document.yml",
            ".github/workflows/_docker_document.yml",
        ])
        job = workflow["jobs"]["update-docker-hub-description"]
        self.assertEqual(job["uses"], "./.github/workflows/_docker_document.yml")
        self.assertEqual(job["with"]["image"], "${{ vars.DOCKER_USERNAME }}/jetify-devbox")
        self.assertEqual(job["with"]["docker-username"], "${{ vars.DOCKER_USERNAME }}")
        self.assertEqual(job["with"]["markdown-file"], "README.md")
        self.assertEqual(job["secrets"]["docker-password"], "${{ secrets.DOCKER_PASSWORD }}")

    def test_readme_documents_image_use_and_version_updates(self):
        text = README.read_text(encoding="utf-8")
        for heading in ("Features", "Quick start", "VS Code and devcontainers", "Version updates"):
            self.assertIn(heading, text)
        self.assertNotIn("DOCKER_PASSWORD", text)


if __name__ == "__main__":
    unittest.main()
