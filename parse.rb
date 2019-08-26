#!/usr/bin/env ruby
require 'csv'
require 'byebug'
require 'yaml'
require 'ynab'

class Parse

  class << self
    def perform
      Dir.foreach('./') do |item|
        next unless item.include?('csv')
        transactions = CsvParser.new(item).parse
        push_to_ynab(transactions)
      end
    end

    def push_to_ynab(transactions)
      return unless transactions.any?
      config = YAML.load(File.read("maps.yml"))
      access_token = config[:ynab][:access_token]
      budget_id = config[:ynab][:budget_id]
      ynab_api = YNAB::API.new(access_token)
      transaction_wrapper = YNAB::SaveTransactionsWrapper.new(transactions: transactions)
      ynab_api.transactions.create_transaction(budget_id, transaction_wrapper)
    rescue YNAB::ApiError => error
      byebug
    end
  end
end

class CsvParser

  def initialize(file_name)
    @file_name = file_name
    @map = RowParser.new(file_name.dup)
  end

  def parse
    parsing = false
    transactions = []
    CSV.foreach(@file_name , :headers => false) do |row|
      next unless (parsing || @map.headers?(row))
      if parsing
        transaction = @map.parse(row)
        transactions << transaction
      else
        parsing = true
      end
    end
    transactions
  end
end

class RowParser
  def initialize(bank)
    maps = YAML.load(File.read("maps.yml"))
    bank.slice!('.csv')
    @map = maps[:banks][bank]
    @account_id = @map[:account_id]
    @date_format = @map[:date_format]
    @amount_format = @map[:amount_format]
    @import_ids = {}
    raise 'No map for Bank' unless @map
  end

  def headers?(row)
    @payee_index = index_of_column(row, :payee)
    @amount_index = index_of_column(row, :amount)
    @date_index = index_of_column(row, :date)
    return true if @payee_index
  end

  def index_of_column(row, column)
    header = @map[column]
    if header.kind_of?(Array)
      header.map{|item| row.index(item)}
    else
      row.index(header)
    end
  end

  attr_accessor :payee_index, :amount_index, :date_index
  
  def parse(row)
    row = parse_row(row)
    YNAB::SaveTransaction.new(
      payee_name: row[:payee],
      date: row[:date],
      amount: row[:amount],
      import_id: import_id(row),
      cleared: 'cleared',
      account_id: @account_id
    )
  end

  def parse_row(row)
    {
      payee: parse_column(row, payee_index),
      date: Date.strptime(parse_column(row, date_index), @date_format),
      amount: amount(parse_column(row, amount_index)),
    }
  end

  def parse_column(row, column_index)
    if column_index.kind_of?(Array)
      column_index.map{|column| row[column]}.join(' ')
    else
      row[column_index]
    end
  end

  def amount(amount)
    parsed_amount = (1000*Float(amount)).floor
    return parsed_amount unless @amount_format == 'negative'
    (parsed_amount * -1)
  end
  
  def import_id(row)
    base_id = "YNAB:#{row[:amount]}:#{row[:date].strftime("%Y-%m-%d")}"
    if @import_ids[base_id]
      @import_ids[base_id] += 1
    else
      @import_ids[base_id] = 1
    end
    "#{base_id}:#{@import_ids[base_id]}"
  end
end

Parse.perform