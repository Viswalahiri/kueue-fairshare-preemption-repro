# Build a throwaway TestArticleARepro from upstream TestFairPreemptions plus article_a_cases.go.txt.
# The generated file keeps Kueue's Apache-2.0 header and is written into a worktree, not this repo.
import sys
src=open(sys.argv[1]).read().split('\n')
cases=open(sys.argv[2]).read()
# function bounds
s=next(i for i,l in enumerate(src) if l.startswith('func TestFairPreemptions('))
e=next(i for i in range(s+1,len(src)) if src[i]=='}')
head=src[:next(i for i,l in enumerate(src) if l.startswith('func '))]
body=src[s:e+1]
body[0]=body[0].replace('TestFairPreemptions','TestArticleARepro')
txt='\n'.join(body)
i=txt.index('cases := map[string]struct {'); j=txt.index('}{',i)+2
k=txt.index('\n\tfor name, tc := range cases {')
k=txt.rindex('\n\t}',j,k)
txt=txt[:j]+'\n'+cases+txt[k:]
txt=txt.replace('cases := map','halfWl := *utiltestingapi.MakeWorkload("unit", "").Request(corev1.ResourceCPU, "500m")\n\t_ = unitWl\n\t_ = baseCQs\n\tcases := map',1)
txt=txt.replace('\t\t\tif diff := cmp.Diff(tc.wantPreempted, gotTargets','\t\t\tt.Logf("REPRO %s targets=%v", name, sets.List(gotTargets))\n\t\t\tif diff := cmp.Diff(tc.wantPreempted, gotTargets',1)
txt=txt.replace('t.Errorf("Issued preemptions','t.Logf("(no want set) Issued preemptions',1)
open(sys.argv[3],'w').write('\n'.join(head)+'\n'+txt+'\n')
