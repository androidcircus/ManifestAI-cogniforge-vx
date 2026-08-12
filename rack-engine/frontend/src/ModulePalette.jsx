import React from "react";

export default function ModulePalette({ modules, onReload }) {
  return (
    <aside className="w-56 bg-gray-900 border-r border-gray-700 p-3 overflow-y-auto shrink-0">
      <div className="flex items-center justify-between mb-3">
        <span className="text-sm font-semibold text-gray-200">Modules</span>
        <button
          onClick={onReload}
          className="text-xs text-cyan-400 hover:underline"
        >
          Reload
        </button>
      </div>
      {modules.length === 0 && (
        <div className="text-xs text-gray-500">No modules loaded.</div>
      )}
      {modules.map((m) => (
        <div
          key={m.id}
          draggable
          onDragStart={(e) => {
            e.dataTransfer.setData("application/reactflow", m.id);
            e.dataTransfer.effectAllowed = "move";
          }}
          className="p-3 mb-2 rounded-md bg-gray-800 border border-gray-700 cursor-grab hover:border-cyan-400 hover:bg-gray-700"
        >
          <div className="text-sm text-white">{m.name}</div>
          <div className="text-xs text-gray-400">
            {m.id} &middot; {m.category}
          </div>
        </div>
      ))}
    </aside>
  );
}
