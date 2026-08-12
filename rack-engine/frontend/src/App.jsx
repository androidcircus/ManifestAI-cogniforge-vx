import React, { useCallback, useEffect, useState } from "react";
import useWebSocket from "react-use-websocket";
import ModulePalette from "./ModulePalette";
import RackCanvas from "./RackCanvas";
import PropertyPanel from "./PropertyPanel";
import { API_BASE, WS_BASE, fetchModules, generatePipeline } from "./api";

export default function App() {
  const [nodes, setNodes] = useState([]);
  const [edges, setEdges] = useState([]);
  const [selected, setSelected] = useState(null);
  const [modules, setModules] = useState([]);
  const [deploying, setDeploying] = useState(false);
  const [result, setResult] = useState(null);

  const { lastJsonMessage } = useWebSocket(WS_BASE, {
    onMessage: (event) => {
      try {
        setResult(JSON.parse(event.data));
      } catch {
        /* ignore non-JSON frames */
      }
    },
  });

  useEffect(() => {
    fetchModules()
      .then(setModules)
      .catch(() => setModules([]));
  }, []);

  const handleReloadModules = useCallback(() => {
    fetchModules()
      .then(setModules)
      .catch(() => setModules([]));
  }, []);

  const updateNodeParam = useCallback((nodeId, key, value) => {
    setNodes((nds) =>
      nds.map((n) =>
        n.id === nodeId
          ? { ...n, data: { ...n.data, params: { ...(n.data.params || {}), [key]: value } } }
          : n
      )
    );
    setSelected((sel) =>
      sel && sel.id === nodeId
        ? { ...sel, data: { ...sel.data, params: { ...(sel.data.params || {}), [key]: value } } }
        : sel
    );
  }, []);

  const handleDeploy = async () => {
    if (nodes.length === 0) {
      setResult({ error: "Add at least one module to the canvas." });
      return;
    }
    setDeploying(true);
    setResult(null);
    try {
      const payload = {
        name: "demo-pipeline",
        modules: nodes.map((n) => ({
          id: n.id,
          type: n.data.moduleId,
          params: n.data.params || {},
        })),
        connections: edges.map((e) => ({
          id: e.id,
          source: e.source,
          source_handle: e.sourceHandle || "out",
          target: e.target,
          target_handle: e.targetHandle || "in",
        })),
      };
      const res = await generatePipeline(payload);
      setResult(res);
    } catch (err) {
      setResult({ error: err.response?.data?.detail || err.message });
    } finally {
      setDeploying(false);
    }
  };

  return (
    <div className="flex h-screen">
      <ModulePalette modules={modules} onReload={handleReloadModules} />

      <div className="flex-1 flex flex-col min-w-0">
        <header className="h-12 bg-gray-800 text-white flex items-center justify-between px-4 border-b border-gray-700">
          <span className="font-semibold">CogniForge Rack</span>
          <span className="text-xs text-gray-400">{API_BASE}</span>
          <button
            onClick={handleDeploy}
            disabled={deploying}
            className="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-4 py-1 rounded text-sm"
          >
            {deploying ? "Deploying..." : "Deploy Pipeline"}
          </button>
        </header>

        <RackCanvas
          nodes={nodes}
          edges={edges}
          setNodes={setNodes}
          setEdges={setEdges}
          onSelect={setSelected}
        />
      </div>

      <PropertyPanel node={selected} onUpdate={updateNodeParam} />

      {result && (
        <div className="fixed bottom-4 right-4 w-80 bg-gray-800 border border-gray-600 rounded p-3 text-xs text-white shadow-lg">
          <div className="flex justify-between items-center mb-1">
            <span className="font-semibold">Deployment</span>
            <button onClick={() => setResult(null)} className="text-gray-400 hover:text-white">
              x
            </button>
          </div>
          {result.error ? (
            <div className="text-red-400">{result.error}</div>
          ) : (
            <div>
              <div>Pipeline: {result.pipeline_id}</div>
              <div>Workflow: {result.workflow_name}</div>
              <div>Status: {result.status}</div>
            </div>
          )}
          {lastJsonMessage && (
            <div className="mt-2 border-t border-gray-600 pt-1 text-gray-400">
              {JSON.stringify(lastJsonMessage)}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
