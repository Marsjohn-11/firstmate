# Definition of done
Delivery contract: mode=direct-PR forge=external
Ship branch: fm/ext-t1
This task ships **direct-PR** through an external review tool: the tool uploads a snapshot of your local commits itself, so you never push a branch to publish, and there is no pull request to open.
The task is complete only when committed on your branch.
Before uploading, push a durable copy to the backup remote as your first rule names; your done is accepted only when that copy holds your HEAD.
Follow the review tool instructions below to validate, upload, and bring the review to the stopping point they name.
Write the review title and description in plain English for a reviewer who lacks your context, with no direct address.
Then append `done [at=<epoch>]: review {url} uploaded for review` to the status file and stop, with the review's full URL exactly as the tool printed it.
Commit nothing after uploading; if you must change the work, commit it, refresh the backup copy, and upload again before reporting done.
Do NOT run /no-mistakes. A human approves and merges the review; firstmate relays the outcome.

## Review tool instructions (home configuration)
Run `acme-review upload --draft` to upload your local commits; it prints the review URL.
