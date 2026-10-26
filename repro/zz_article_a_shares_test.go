package scheduler

// Repro helper (not upstream). For the v0.19.x cache API.
// Computes the ClusterQueue weighted shares Kueue's cache would report
// for the kind scenarios in the README, and maps them the way the
// ClusterQueue controller does: status = ceil(share), or MaxInt64 when
// the share is +Inf (pkg/controller/core/helpers.go WeightedShare);
// metric = NaN when the share is +Inf (clusterqueue_controller.go).

import (
	"fmt"
	"math"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"

	kueue "sigs.k8s.io/kueue/apis/kueue/v1beta2"
	utiltesting "sigs.k8s.io/kueue/pkg/util/testing"
	utiltestingapi "sigs.k8s.io/kueue/pkg/util/testing/v1beta2"
)

func TestArticleAShares(t *testing.T) {
	now := time.Now()
	type state struct {
		weightA string
		wls     map[string]int // CQ -> number of 500m workloads
	}
	cases := map[string]state{
		"Z  (a=0: a1 | b=1: b1,b2,b3)":          {"0", map[string]int{"team-a": 1, "team-b": 3}},
		"Zc (a=1: a1 | b=1: b1,b2,b3)":          {"1", map[string]int{"team-a": 1, "team-b": 3}},
		"Z2 (a=0: a1..a4 borrowing | b empty)": {"0", map[string]int{"team-a": 4, "team-b": 0}},
		"Z2 a=0: a1..a2 (borrowing 500m)":       {"0", map[string]int{"team-a": 2, "team-b": 0}},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			ctx, log := utiltesting.ContextWithLog(t)
			c := New(utiltesting.NewFakeClient(), WithFairSharing(true))
			c.AddOrUpdateResourceFlavor(log, utiltestingapi.MakeResourceFlavor("default").Obj())
			_ = c.AddOrUpdateCohort(utiltestingapi.MakeCohort("all").
				ResourceGroup(*utiltestingapi.MakeFlavorQuotas("default").Resource(corev1.ResourceCPU, "1").Obj()).Obj())
			cqs := map[string]*kueue.ClusterQueue{
				"team-a": utiltestingapi.MakeClusterQueue("team-a").Cohort("all").FairWeight(resource.MustParse(tc.weightA)).
					ResourceGroup(*utiltestingapi.MakeFlavorQuotas("default").Resource(corev1.ResourceCPU, "500m").Obj()).Obj(),
				"team-b": utiltestingapi.MakeClusterQueue("team-b").Cohort("all").FairWeight(resource.MustParse("1")).
					ResourceGroup(*utiltestingapi.MakeFlavorQuotas("default").Resource(corev1.ResourceCPU, "500m").Obj()).Obj(),
			}
			for _, n := range []string{"team-a", "team-b"} {
				if err := c.AddClusterQueue(ctx, cqs[n]); err != nil {
					t.Fatal(err)
				}
			}
			for _, n := range []string{"team-a", "team-b"} {
				for i := 1; i <= tc.wls[n]; i++ {
					wl := utiltestingapi.MakeWorkload(fmt.Sprintf("%s-%d", n, i), "default").
						Request(corev1.ResourceCPU, "500m").SimpleReserveQuota(kueue.ClusterQueueReference(n), "default", now).Obj()
					c.AddOrUpdateWorkload(log, wl)
				}
			}
			for _, n := range []string{"team-a", "team-b"} {
				s, err := c.Usage(cqs[n])
				if err != nil {
					t.Fatal(err)
				}
				status := int64(math.MaxInt64)
				metric := math.NaN()
				if !math.IsInf(s.WeightedShare, 1) {
					status = int64(math.Ceil(s.WeightedShare))
					metric = s.WeightedShare
				}
				t.Logf("SHARE %s %s: precise=%v status.fairSharing.weightedShare=%d kueue_cluster_queue_weighted_share=%v", name, n, s.WeightedShare, status, metric)
			}
		})
	}
}
