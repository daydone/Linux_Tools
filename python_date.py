from datetime import datetime, timedelta

ninety_days_ago = datetime.now() - timedelta(days=90)
print (datetime.now,'-',ninety_days_ago)
