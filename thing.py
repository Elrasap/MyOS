import yfinance as yf

ticker = yf.Ticker("RDW")

data = ticker.history(period="1d", interval="1m")
today_open = data["Open"].iloc[0]
print(today_open)