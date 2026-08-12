import React from "react";

export default function PropertyPanel({ node, onUpdate }) {
  if (!node) {
    return (
      <aside className="w-64 bg-gray-900 border-l border-gray-700 p-3 text-xs text-gray-400 shrink-0">
        Select a module on the canvas to edit its parameters.
      </aside>
    );
  }

  const params = node.data.params || {};

  const setParam = (key, value) => onUpdate(node.id, key, value);

  return (
    <aside className="w-64 bg-gray-900 border-l border-gray-700 p-3 overflow-y-auto shrink-0">
      <div className="text-sm font-semibold text-white mb-2">
        {node.data.moduleId}
      </div>
      <label className="block text-xs text-gray-400 mb-1">Parameters</label>
      {Object.keys(params).length === 0 && (
        <div className="text-xs text-gray-500 mb-2">No parameters yet.</div>
      )}
      {Object.entries(params).map(([key, value]) => (
        <div key={key} className="mb-2">
          <label className="block text-xs text-gray-400">{key}</label>
          <input
            className="w-full bg-gray-800 border border-gray-600 rounded px-2 py-1 text-sm text-white"
            value={value}
            onChange={(e) => setParam(key, e.target.value)}
          />
        </div>
      ))}
      {node.data.moduleId === "wan21" && (
        <button
          className="mt-3 w-full bg-gray-800 border border-gray-600 rounded py-1 text-xs text-cyan-300 hover:border-cyan-400"
          onClick={() => {
            setParam("image_url", "https://example.com/cat.jpg");
            setParam("duration", "5");
          }}
        >
          Set example params
        </button>
      )}
    </aside>
  );
}
