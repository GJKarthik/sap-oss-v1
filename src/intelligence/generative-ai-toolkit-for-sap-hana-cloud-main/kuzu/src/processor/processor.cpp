#include "processor/processor.h"

/**
 * P3-164: QueryProcessor - Physical Plan Execution
 * 
 * Purpose:
 * Executes physical query plans. Decomposes plans into parallel tasks,
 * schedules them on the task scheduler, and coordinates execution.
 * 
 * Architecture:
 * ```
 * PhysicalPlan
 *   │
 *   └── QueryProcessor::execute()
 *         │
 *         ├── 1. Get Sink operator (root)
 *         ├── 2. Create root ProcessorTask
 *         ├── 3. decomposePlanIntoTask()
 *         │     └── Recursively create child tasks
 *         ├── 4. initTask()
 *         │     └── Mark single-threaded if needed
 *         ├── 5. taskScheduler->scheduleTaskAndWaitOrError()
 *         └── 6. Return QueryResult from Sink
 * ```
 * 
 * Task Decomposition:
 * ```
 * Physical Operator Tree           Task Tree
 * ─────────────────────           ──────────
 * Sink (ResultCollector)    →     ProcessorTask (root)
 *   │                               │
 *   └── Scan                        └── (same task, linear)
 * 
 * Sink (ResultCollector)    →     ProcessorTask (root)
 *   │                               │
 *   └── HashJoin                    └── ProcessorTask (build child)
 *         ├── Probe (linear)              └── Build pipeline
 *         └── Build (child task)
 * ```
 * 
 * Pipeline Concept:
 * - Operators from source to sink form a pipeline
 * - Sink operators (HashJoinBuild, Aggregate) break pipelines
 * - Each pipeline becomes a ProcessorTask
 * 
 * Parallelism:
 * - Each pipeline can run on multiple threads
 * - Single-threaded if any operator is not parallel
 * - initTask() marks tasks as single-threaded if needed
 * 
 * Execution Flow:
 * 1. decomposePlanIntoTask: Traverse operator tree
 *    - Source operators: Add to progress bar
 *    - Sink operators: Create child task
 *    - Other operators: Stay in current task
 * 
 * 2. initTask: Configure parallelism
 *    - Traverse operators from sink to source
 *    - Mark single-threaded if any operator is non-parallel
 * 
 * 3. scheduleTaskAndWaitOrError: Execute
 *    - Task scheduler runs all tasks
 *    - Child tasks complete before parents
 *    - Progress bar shows pipeline progress
 * 
 * TaskScheduler:
 * - Manages thread pool
 * - Schedules tasks across available threads
 * - Platform-specific QoS on macOS
 * 
 * Output:
 * - QueryResult from sink->getQueryResult()
 * - Contains materialized results or Arrow batches
 */

#include "common/task_system/progress_bar.h"
#include "main/query_result.h"
#include "processor/operator/sink.h"
#include "processor/physical_plan.h"
#include "processor/processor_task.h"

using namespace kuzu::common;
using namespace kuzu::storage;

namespace kuzu {
namespace processor {

#if defined(__APPLE__)
QueryProcessor::QueryProcessor(uint64_t numThreads, uint32_t threadQos) {
    taskScheduler = std::make_unique<TaskScheduler>(numThreads, threadQos);
}
#else
QueryProcessor::QueryProcessor(uint64_t numThreads) {
    taskScheduler = std::make_unique<TaskScheduler>(numThreads);
}
#endif

std::unique_ptr<main::QueryResult> QueryProcessor::execute(PhysicalPlan* physicalPlan,
    ExecutionContext* context) {
    auto lastOperator = physicalPlan->lastOperator.get();
    // The root pipeline(task) consists of operators and its prevOperator only, because we
    // expect to have linear plans. For binary operators, e.g., HashJoin, we  keep probe and its
    // prevOperator in the same pipeline, and decompose build and its prevOperator into another
    // one.
    auto sink = lastOperator->ptrCast<Sink>();
    auto task = std::make_shared<ProcessorTask>(sink, context);
    for (auto i = (int64_t)sink->getNumChildren() - 1; i >= 0; --i) {
        decomposePlanIntoTask(sink->getChild(i), task.get(), context);
    }
    initTask(task.get());
    auto progressBar = ProgressBar::Get(*context->clientContext);
    progressBar->startProgress(context->queryID);
    taskScheduler->scheduleTaskAndWaitOrError(task, context);
    progressBar->endProgress(context->queryID);
    return sink->getQueryResult();
}

void QueryProcessor::decomposePlanIntoTask(PhysicalOperator* op, Task* task,
    ExecutionContext* context) {
    if (op->isSource()) {
        ProgressBar::Get(*context->clientContext)->addPipeline();
    }
    if (op->isSink()) {
        auto childTask = std::make_unique<ProcessorTask>(ku_dynamic_cast<Sink*>(op), context);
        for (auto i = (int64_t)op->getNumChildren() - 1; i >= 0; --i) {
            decomposePlanIntoTask(op->getChild(i), childTask.get(), context);
        }
        task->addChildTask(std::move(childTask));
    } else {
        // Schedule the right most side (e.g., build side of the hash join) first.
        for (auto i = (int64_t)op->getNumChildren() - 1; i >= 0; --i) {
            decomposePlanIntoTask(op->getChild(i), task, context);
        }
    }
}

void QueryProcessor::initTask(Task* task) {
    auto processorTask = ku_dynamic_cast<ProcessorTask*>(task);
    PhysicalOperator* op = processorTask->sink;
    while (!op->isSource()) {
        if (!op->isParallel()) {
            task->setSingleThreadedTask();
        }
        op = op->getChild(0);
    }
    if (!op->isParallel()) {
        task->setSingleThreadedTask();
    }
    for (auto& child : task->children) {
        initTask(child.get());
    }
}

} // namespace processor
} // namespace kuzu
