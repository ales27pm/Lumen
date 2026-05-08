#!/usr/bin/env python3
import argparse, json, random

SEEDS = {
 "weather":["should I bring an umbrella","is it gross outside","weather here"],
 "maps":["closest gas station","show this on map"],
 "outlook":["read unread emails","check my inbox"],
 "memory":["do you remember"],
 "rag":["search my files"],
 "chat":["explain this code","what is recursion"],
 "webSearch":["search web for swift concurrency"],"emailDraft":["draft an email to sam"],"messageDraft":["send a text to alex"],"phoneCall":["call mom"],"contactSearch":["find bob contact"],"calendar":["create event tomorrow"],"reminder":["remind me at 5"],"photos":["find photos from june"],"camera":["take a photo"],"health":["health summary"],"motion":["am i walking"],"files":["read this file"],"trigger":["create trigger every day"],"alarm":["set alarm for 7"],"note":["save this note"],"unknown":["asdf qwerty"]
}
HARD_NEGATIVES=[("explain calendar APIs in Swift","chat"),("what is an alarm clock","chat"),("how does outlook protocol work","chat")]

def main():
 p=argparse.ArgumentParser();p.add_argument('--out',default='intent_dataset.jsonl');p.add_argument('--repeat',type=int,default=20);a=p.parse_args()
 rows=[]
 for i in range(a.repeat):
  for intent,examples in SEEDS.items():
   rows.append({"text":random.choice(examples),"intent":intent})
 for text,intent in HARD_NEGATIVES: rows.append({"text":text,"intent":intent})
 random.shuffle(rows)
 with open(a.out,'w') as f:
  for r in rows: f.write(json.dumps(r)+"\n")
 print(f"wrote {len(rows)} rows to {a.out}")
if __name__=='__main__': main()
