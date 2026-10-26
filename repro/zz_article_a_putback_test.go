// Copyright 2026 The Kueue fair-sharing preemption repro authors.
// SPDX-License-Identifier: Apache-2.0

// Dropped into a Kueue v0.20.3 worktree by repro/run-unit-repro.sh.
// It is a unit test of (*Preemptor).getTargets / fillBackWorkloads.
// It does not talk to a cluster.
package preemption

import (
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	clocktesting "k8s.io/utils/clock/testing"

	kueue "sigs.k8s.io/kueue/apis/kueue/v1beta2"
	schdcache "sigs.k8s.io/kueue/pkg/cache/scheduler"
	"sigs.k8s.io/kueue/pkg/scheduler/flavorassigner"
	preemptexpectations "sigs.k8s.io/kueue/pkg/scheduler/preemption/expectations"
	"sigs.k8s.io/kueue/pkg/scheduler/preemption/policy"
	utiltesting "sigs.k8s.io/kueue/pkg/util/testing"
	utiltestingapi "sigs.k8s.io/kueue/pkg/util/testing/v1beta2"
	"sigs.k8s.io/kueue/pkg/workload"
)

// TestArticleAPutBack asks the v0.20.3 question: candidates ordered
// [8-GPU workload, then 1-GPU workload], preemptor needs 8 GPUs.
// Ordering is the real CandidatesOrdering (most recently admitted first),
// not the slice we happen to pass in.
//
// fillBackWorkloads in pkg/scheduler/preemption/preemption.go is the put-back
// step. getTargets calls it only after a prefix of candidates has been removed
// and the preemptor fits. The loop is `for i := len(targets)-2; i >= 0; i--`,
// so a prefix of length 1 never restores anything.
func TestArticleAPutBack(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	gpu := corev1.ResourceName("nvidia.com/gpu")

	cases := []struct {
		name        string
		gpu8At      time.Time
		gpu1At      time.Time
		wantFirst   string
		wantSecond  string
		putBackRuns bool
	}{
		{
			name:        "8gpu_then_1gpu",
			gpu8At:      now,
			gpu1At:      now.Add(-2 * time.Second),
			wantFirst:   "gpu8",
			wantSecond:  "gpu1",
			putBackRuns: false,
		},
		{
			// Control. The 1-GPU workload is removed first, which is not enough,
			// so the 8-GPU workload is removed too and put-back can restore the 1-GPU one.
			name:        "1gpu_then_8gpu",
			gpu8At:      now.Add(-2 * time.Second),
			gpu1At:      now,
			wantFirst:   "gpu1",
			wantSecond:  "gpu8",
			putBackRuns: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx, log := utiltesting.ContextWithLog(t)

			admitted := []kueue.Workload{
				*utiltestingapi.MakeWorkload("gpu8", "ns").
					Request(gpu, "8").
					Priority(0).
					SimpleReserveQuota("team", "default", tc.gpu8At).
					Obj(),
				*utiltestingapi.MakeWorkload("gpu1", "ns").
					Request(gpu, "1").
					Priority(0).
					SimpleReserveQuota("team", "default", tc.gpu1At).
					Obj(),
			}
			for i := range admitted {
				admitted[i].UID = types.UID(admitted[i].Name)
			}

			var info8, info1 *workload.Info
			for i := range admitted {
				info := workload.NewInfo(log, &admitted[i])
				info.ClusterQueue = "team"
				switch admitted[i].Name {
				case "gpu8":
					info8 = info
				case "gpu1":
					info1 = info
				}
			}
			cmp81 := policy.CandidatesOrdering(log, false, info8, info1, "team", now)
			t.Logf("PUTBACK CandidatesOrdering(gpu8, gpu1)=%d (negative means gpu8 is before gpu1)", cmp81)
			first, second := "gpu8", "gpu1"
			if cmp81 > 0 {
				first, second = "gpu1", "gpu8"
			}
			t.Logf("PUTBACK candidate order: [%s, %s]", first, second)
			if first != tc.wantFirst || second != tc.wantSecond {
				t.Fatalf("candidate order [%s, %s], want [%s, %s]", first, second, tc.wantFirst, tc.wantSecond)
			}

			cl := utiltesting.NewClientBuilder().
				WithLists(&kueue.WorkloadList{Items: admitted}).
				Build()
			cqCache := schdcache.New(cl)
			cqCache.AddOrUpdateResourceFlavor(log, utiltestingapi.MakeResourceFlavor("default").Obj())
			cq := utiltestingapi.MakeClusterQueue("team").
				ResourceGroup(*utiltestingapi.MakeFlavorQuotas("default").Resource(gpu, "9").Obj()).
				Preemption(kueue.ClusterQueuePreemption{
					WithinClusterQueue: kueue.PreemptionPolicyLowerPriority,
				}).
				Obj()
			if err := cqCache.AddClusterQueue(ctx, cq); err != nil {
				t.Fatalf("add cq: %v", err)
			}
			snapshot, err := cqCache.Snapshot(ctx)
			if err != nil {
				t.Fatalf("snapshot: %v", err)
			}

			incoming := utiltestingapi.MakeWorkload("incoming", "ns").
				Request(gpu, "8").
				Priority(100).
				Obj()
			wlInfo := workload.NewInfo(log, incoming)
			wlInfo.ClusterQueue = "team"
			assignment := singlePodSetAssignment(flavorassigner.ResourceAssignment{
				gpu: &flavorassigner.FlavorAssignment{
					Name: "default",
					Mode: flavorassigner.Preempt,
				},
			})

			recorder := &utiltesting.EventRecorder{}
			// nil FairSharing selects the classical strategy. getTargets, which
			// calls fillBackWorkloads, is the same function the fair-sharing path uses.
			preemptor := New(cl, workload.Ordering{}, recorder, nil, false, clocktesting.NewFakeClock(now), nil, preemptexpectations.New(), nil)
			strategies := preemptor.GetPreemptionStrategyIterator(ctx, *wlInfo, snapshot, assignment)
			targets := preemptor.GetTargetsWithStrategy(ctx, strategies)

			gotNames := make([]string, 0, len(targets))
			for _, tgt := range targets {
				key := targetKeyReason(workload.Key(tgt.WorkloadInfo.Obj), tgt.Reason)
				gotNames = append(gotNames, tgt.WorkloadInfo.Obj.Name)
				t.Logf("PUTBACK target %s", key)
			}
			t.Logf("PUTBACK final target names: %v", gotNames)

			spared1 := true
			kept8 := false
			for _, n := range gotNames {
				if n == "gpu1" {
					spared1 = false
				}
				if n == "gpu8" {
					kept8 = true
				}
			}
			if !spared1 || !kept8 || len(gotNames) != 1 {
				t.Fatalf("final targets %v, want only gpu8 (gpu1 spared)", gotNames)
			}

			// fillBackWorkloads (pkg/scheduler/preemption/preemption.go) loops
			// `for i := len(targets)-2; i >= 0; i--`. getTargets calls it with the
			// prefix removed so far, which is not the same as the slice returned
			// after put-back.
			if tc.putBackRuns {
				t.Log("PUTBACK fillBackWorkloads does run on the 1-GPU workload: it is the earlier candidate, removing it does not free 8 GPUs, so the prefix that first fits is [gpu1, gpu8]. The loop starts at index 0, adds gpu1 back, the incoming 8-GPU workload still fits (nominal 9, gpu1 restored), and gpu1 is dropped from the target list. The 1-GPU workload is spared by that put-back.")
			} else {
				t.Log("PUTBACK fillBackWorkloads does not restore the 1-GPU workload. The 8-GPU workload is first and already frees 8 GPUs, so the prefix that first fits has length 1. fillBackWorkloads is still called, and its loop start len(targets)-2 is -1, so the loop body does not run. The 1-GPU workload was never removed. It is spared, and the put-back step is not what spares it.")
			}
		})
	}
}
