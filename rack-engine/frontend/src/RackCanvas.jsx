import React, { useCallback, useRef } from "react";
import {
  ReactFlow,
  addEdge,
  applyNodeChanges,
  applyEdgeChanges,
  Background,
  Controls,
  Handle,
  Position,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";

function ModuleNode({ data, selected }) {
  const hasParams = Object.keys(data.params || {}).length > 0;
  return (
    <div
      className={`px-4 py-2 rounded-md border bg-gray-800 text-white text-xs ${
        selected ? "border-cyan-400" : "border-gray-600"
      }`}
    >
      <Handle type="target" position={Position.Left} />
      <div className="font-semibold">{data.moduleId}</div>
      {hasParams && (
        <div className="text-gray-400 mt-1 max-w-[200px] truncate">
          {JSON.stringify(data.params)}
        </div>
      )}
      <Handle type="source" position={Position.Right} />
    </div>
  );
}

const nodeTypes = { module: ModuleNode };

export default function RackCanvas({ nodes, edges, setNodes, setEdges, onSelect }) {
  const flow = useRef(null);

  const onConnect = useCallback(
    (params) => setEdges((eds) => addEdge({ ...params, animated: true }, eds)),
    [setEdges]
  );
  const onNodesChange = useCallback(
    (changes) => setNodes((nds) => applyNodeChanges(changes, nds)),
    [setNodes]
  );
  const onEdgesChange = useCallback(
    (changes) => setEdges((eds) => applyEdgeChanges(changes, eds)),
    [setEdges]
  );

  const onDragOver = useCallback((event) => {
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
  }, []);

  const onDrop = useCallback(
    (event) => {
      event.preventDefault();
      const moduleId = event.dataTransfer.getData("application/reactflow");
      if (!moduleId) return;
      const position = flow.current
        ? flow.current.screenToFlowPosition({ x: event.clientX, y: event.clientY })
        : { x: 0, y: 0 };
      const id = `${moduleId}-${Date.now()}`;
      setNodes((nds) => [
        ...nds,
        { id, type: "module", position, data: { moduleId, params: {} } },
      ]);
    },
    [setNodes]
  );

  return (
    <div className="flex-1 relative">
      <ReactFlow
        ref={flow}
        nodes={nodes}
        edges={edges}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        onConnect={onConnect}
        onNodeClick={(_, node) => onSelect(node)}
        onPaneClick={() => onSelect(null)}
        onDrop={onDrop}
        onDragOver={onDragOver}
        nodeTypes={nodeTypes}
        fitView
      >
        <Background />
        <Controls />
      </ReactFlow>
    </div>
  );
}
