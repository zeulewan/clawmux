/**
 * Tool renderer registry — provides headerText and inputText for each tool.
 * The ToolUseContent component handles the HTML structure with exact CSS classes.
 */

const renderers = {
  Bash: {
    headerText: (c) => c.input?.description || c.input?.command?.slice(0, 80) || '',
    inputText: (c) => c.input?.command || '',
  },
  Read: {
    headerText: (c) => c.input?.file_path || '',
    inputText: (c) => c.input?.file_path || '',
  },
  Write: {
    headerText: (c) => c.input?.file_path || '',
    inputText: (c) => c.input?.content?.slice(0, 500) || '',
  },
  Edit: {
    headerText: (c) => c.input?.file_path || '',
    inputText: (c) => {
      const old = c.input?.old_string || '';
      const nw = c.input?.new_string || '';
      return `- ${old.slice(0, 200)}\n+ ${nw.slice(0, 200)}`;
    },
  },
  Glob: {
    headerText: (c) => `pattern: "${c.input?.pattern || ''}"`,
    inputText: (c) => c.input?.pattern || '',
  },
  Grep: {
    headerText: (c) => `pattern: "${c.input?.pattern || ''}"`,
    inputText: (c) => c.input?.pattern || '',
  },
  Agent: {
    headerText: (c) => c.input?.description || c.input?.prompt?.slice(0, 60) || '',
    inputText: (c) => c.input?.prompt?.slice(0, 500) || '',
  },
  TodoWrite: {
    headerText: () => 'Update tasks',
    inputText: (c) => JSON.stringify(c.input, null, 2)?.slice(0, 500) || '',
  },
  WebSearch: {
    headerText: (c) => c.input?.query || '',
    inputText: (c) => c.input?.query || '',
  },
  WebFetch: {
    headerText: (c) => c.input?.url || '',
    inputText: (c) => c.input?.url || '',
  },
  Search: {
    headerText: (c) => c.input?.query || c.input?.pattern || '',
    inputText: (c) => c.input?.query || c.input?.pattern || '',
  },
  Skill: {
    headerText: (c) => c.input?.skill || '',
    inputText: (c) => c.input?.skill || '',
  },
  ToolSearch: {
    headerText: (c) => c.input?.query || '',
    inputText: (c) => c.input?.query || '',
  },
  NotebookEdit: {
    headerText: () => 'Edit notebook',
    inputText: (c) => JSON.stringify(c.input, null, 2)?.slice(0, 500) || '',
  },
};

const defaultRenderer = {
  headerText: (c) => JSON.stringify(c.input || {}).slice(0, 80),
  inputText: (c) => JSON.stringify(c.input, null, 2)?.slice(0, 500) || '',
};

export function getToolRenderer(name) {
  const effectiveName = name === 'Task' ? 'Agent' : name;
  return renderers[effectiveName] || defaultRenderer;
}
